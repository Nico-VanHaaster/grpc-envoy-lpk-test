
# grpc-envoy-lpk-test

  

This is a sample application that shows how using the envoy `type.googleapis.com/envoy.extensions.filters.http.grpc_json_transcoder.v3.GrpcJsonTranscoder` does not work with Bridge to Kubernetes. I hope to update this example to highlight how it can work.

This example also assumes the following

1. Access to a Azure Kubernetes Service with Bridge to Kubernetes setup and available.
2. Access to a Azure Container Registry (or other registry) and working knowledge to Build & Push images to a container repository.
3. Working knowledge of Bridge to Kubernetes
4. Advanced knowledge of Envoy Proxy
5. Working knowledge of gRPC, Protobuf and API annotations
 

# Intro
 

This example takes a standard dotnet core GRPC service and employs a REST JSON to gRPC transcoder from Envoy proxy. It is worth noting this sample works as-is without using Bridge to Kubernetes. With this sample we expect "external" traffic to be sent as standard HTTP/1 \ HTTP/2 JSON requests to API endpoints. These API endpoints such as `/greeter` are then translated using the `type.googleapis.com/envoy.extensions.filters.http.grpc_json_transcoder.v3.GrpcJsonTranscoder` to gRPC and rewritten to their actual endpoints. For example a POST request sent to `http://mydomain.com/sayHello` over standard REST is transcoded to gRPC to activate the service `http://mydomain.com/greet.Greeter/SayHello` with the appropriate headers, body and response types.

The application consits of 3 key components.

1. `front-envoy`: This is the envoy that we will use to handle ingress, routing and https termination to work around the limitations of Bridge. This will also provide our initial route propogation for the `kubernetes-route-as: GENERATED_NAME` header. This service will run on port 8080 and forward requests to the routing end point.
2. `greet-api-envoy`: This is a secondary Envoy proxy that will be used for the gRPC transcoding as well as provide support for additional "non-gRPC" routes (if required) the service will be available on port 8000
3. `greet-api`: This is the "micro service" or GRPC Application running. Requests will be routed to this application using HTTP/2 on port 8100

The typical request pathway will be as follows

>  Public HTTP(s) -> `front-envoy` -> http -> `greet-api-envoy` -> gRPC (http/2) -> `greet-api`
  

# Build & Push Docker Image

  To create the Greeter API a Container Registry will be required. To build the application use the existing `Dockerfile` provided. Replace `<acr registry>` with your Azure Container Registry (or other docker registry)
```
cd src\GrpcGreeter
docker build -t <acr registry>/greet-api:latest -f .\Dockerfile ..\
docker push <acr registry>.azurecr.io/greet-api:latest
```
  
# Deploy Charts

Deploy the three components required. View the `values.yaml` file for configuration options. This example assumes the `greeter` namespace.  

## Deploy the front envoy

The front-envoy has configuration values for the ingress host name.
`\charts\front-envoy> helm upgrade --install -name front-envoy -n greeter .`

## Deploy the greet api
The `greet api` can only be deployed once pushed to a valid docker repo. Ensure that `values.yaml` file is up to date.

- `imageRepository`: Sets the repository location
- `imageName`: The name of the image pushed
- `imageTag`: The tag to pull
- `imagePullSecret`: The secret to use to pull the image

`\charts\greet-api> helm upgrade --install -name greet-api -n greeter .`

  

## Deploy the greeter grpc envoy
The `greet-envoy` does the transcoding work for the JSON to gRPC requests.

`\charts\greet-envoy> helm upgrade --install -name greet-api-envoy -n greeter .`

# Test the Application without Bridge

Testing the Application can be done by using PostMan or any other REST client setting the appropriate values.

- Path: `http://<myingress>/sayHello`
- Method: `POST`
- Headers
   - `Accept: application/json`
   - `Content-Type: application/json`
- Body
```
{
    "name": "gRPC Rest"
}
```

This should result in a 200 OK message with an echo of your request such as 
```
{
    "message": "Hello gRPC Rest"
}
```
This confirms the application as described works

# Configure Bridge to Kubernetes

Configure the `GrpcGreeter` application to use Bridge to Kubernetes and select the `greet-api` as the service to forward. Ensure you select the work in isolation option and note down the GENERATED_NAME. This generated name will need to be added to the `front-envoy` configuration.

Open the file `charts/front-envoy/templates/envoy-configmap.yaml` and locate the section below (line 28) replacing `GENERATED_NAME` with the generated name from the Bridge to Kubernetes dialog.

```
request_headers_to_add:
  - header:
      key: "kubernetes-route-as"
      value: "GENERATED_NAME"
  append: true
```
After this is updated redeploy the `front-envoy` as above with the command `\charts\front-envoy> helm upgrade --install -name front-envoy -n greeter .`

# Testing with Bridge to Kubernetes



Once the front-envoy is running again with the correct `kubernetes-route-as` header propogration start the Bridge to Kuberenetes debug session and issue the same request. This should eventually end up with a `503: Service Temporarily Unavailable` response. Additional log details can be found in the Bridge to Kubernetes Envoy logs (within the pods themselves) with the statements below.

```
[2020-11-12 05:29:05.623][23][trace][connection] [source/common/network/raw_buffer_socket.cc:25] [C5] read returns: 17
[2020-11-12 05:29:05.623][23][trace][connection] [source/common/network/raw_buffer_socket.cc:39] [C5] read error: Resource temporarily unavailable
[2020-11-12 05:29:05.623][23][trace][http] [source/common/http/http1/codec_impl.cc:470] [C5] parsing 17 bytes
[2020-11-12 05:29:05.623][23][debug][client] [source/common/http/codec_client.cc:127] [C5] protocol error: http/1.1 protocol error: HPE_INVALID_CONSTANT
[2020-11-12 05:29:05.623][23][debug][connection] [source/common/network/connection_impl.cc:109] [C5] closing data_to_write=0 type=1
……
[2020-11-12 05:29:05.623][23][debug][http] [source/common/http/conn_manager_impl.cc:1706] [C0][S4506007496968355228] encoding headers via codec (end_stream=true):
':status', '200'
'content-type', 'application/grpc'
'grpc-status', '14'
'grpc-message', 'upstream connect error or disconnect/reset before headers. reset reason: connection termination'
'date', 'Thu, 12 Nov 2020 05:29:05 GMT'
'server', 'envoy'
```


Disconnecting the debug session and after the Bridge to Kuberenets pods \ services have been removed this request starts working again.


# Potential Remedy Steps

In our testing with the GRPC transconder in envoy we have found some specific cluster configuration that should be added to ensure the `HTTP/2` protocol is used when making the upstream request. Notably the highlighted section below is required for envoy to treat this as a `HTTP/2` connection. However we have not been able to confirm if this is the case with Bridge to Kubernetes.

```
clusters:
      - name: greet_service
        connect_timeout: 120s
        type: logical_dns
        lb_policy: round_robin
        http2_protocol_options: {} <---- This line
        load_assignment:
          cluster_name: greet_service
          endpoints:
          - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: greet-api
                    port_value: 8100
```
  

# Additional Notes

The greet.pb file is required by the envoy transcoder to convert the REST JSON request to a gRPC request. This file was generated with the command.

`\src\GrpcGreeter\Protos> protoc -I. -I../../Protos --include_imports --include_source_info --descriptor_set_out=greet.pb *.proto`# grpc-envoy-lpk-test
