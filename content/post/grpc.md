+++
categories = ["default"]
date = "2018-05-31T16:44:17+03:00"
tags = ["go", "grpc", "eng"]
title = "Using GRPC in GO"

+++

Nowadays it's hard to avoid microservices if you do programming.

A couple of years ago, when I started to use microservices, I used to do HTTP based REST API for my projects. 
REST API is a good choice for CRUD based API but it could be odd for API designed more RPC alike style.
I also have tried JSON-RPC for some projects. It provides a more clear model for RPC based style, however, it has disadvantages:

- it is HTTP based, but it ignores HTTP errors which people with RESP background used to use as a data model errors (404 for not found, 400 for validation errors, 500 for background errors, etc). In JSON-RPC HTTP errors are just transport level errors.
- Performing requests to JSON-RPC server is complicated. You either need to construct the corresponding JSON manually or prepare some client library based on the interface of your server.

In the modern days, when you are going to start new microservice oriented architecture your choice is obvious - GRPC.


<a href="https://grpc.io/">GRPC</a> is a RPC system introduced by Google. It is language agnostic, it uses HTTP/2 as a transport with the expected results, it uses protobuf for serialization\deserialization.

In this quick tutorial, I want to show how to implement a basic server with a client for it.
I will create the server using GO and I will create the client using Python.
Let's implement simple storage API. We will provide a method to store the arbitrary string and a method to lookup stored value.

Let's first define our interface using protobuf:

```
syntax="proto3";
package tutorial;

option go_package="tutorial";


message Value {
    string content = 1;
}

message Key {
    string key = 2;
}

service StorageService {
    rpc Put(Value) returns (Key);
    rpc Deobfuscate(Key) returns (Value);
}
```

We will use this definition as the source of truth - client code and server code, both would be based on this definition. We will introduce a little bit of code generating. For generating golang code for server first of all we need to install *protoc* and golang grpc plugin for it.
1. Download and install protoc using following instruction https://developers.google.com/protocol-buffers/docs/downloads.html
2. Run go get to install golang plugin
```
go get -u github.com/golang/protobuf/protoc-gen-go
```


Now we can use the following command for generating code:

```
protoc -I=$SRC_DIR --go_out=$DST_DIR $SRC_DIR/*.proto
```

Let's create simple Makefile:

```
SRC_DIR=proto
SERVER_DST_DIR="server/proto"


golang:
    @mkdir -p ${SERVER_DST_DIR}
    @protoc -I=${SRC_DIR} --go_out=plugins=grpc:${SERVER_DST_DIR} ${SRC_DIR}/service.proto

generate: golang
```

Running `make generate` will give us generated `server/proto/service.pb.go` which contain all the defined data structures and interface for service:
```
// Server API for StorageService service

type StorageServiceServer interface {
    Put(context.Context, *Value) (*Key, error)
    Deobfuscate(context.Context, *Key) (*Value, error)
}
```


All we need now is to implement golang object which implements this interface, start grpc server and register our object in it.
```
package main

import (
    "errors"
    "fmt"
    "net"
    "sync"

    "crypto/md5"
    "io"

    proto "github.com/soider/grpc_example/server/proto"
    "golang.org/x/net/context"
    "google.golang.org/grpc"
    "google.golang.org/grpc/reflection"
)

type inMemoryStorage struct {
    sync.Mutex
    storage map[string]string
}

var errorNotFound = errors.New("Value not found")

// Get takes key, looks up value in memory and returns it.
func (ims *inMemoryStorage) Get(ctx context.Context, key *proto.Key) (*proto.Value, error) {
    ims.Lock()
    defer ims.Unlock()
    if value, found := ims.storage[key.GetKey()]; found {
        return &proto.Value{Content: value}, nil
    }
    return nil, errorNotFound
}

// Put takes value, stores it in memory using md5 hash of value as a key, returns the key to the client
func (ims *inMemoryStorage) Put(ctx context.Context, value *proto.Value) (*proto.Key, error) {
    hash := md5.New()
    io.WriteString(hash, value.Content)
    key := fmt.Sprintf("%x", hash.Sum(nil))
    ims.Lock()
    defer ims.Unlock()
    ims.storage[key] = value.Content
    return &proto.Key{Key: key}, nil
}

func newInMemoryStorage() *inMemoryStorage {
    return &inMemoryStorage{
        storage: make(map[string]string),
    }
}

func main() {
    // Creates new server
    server := grpc.NewServer()
    // Creates new listener
    grpcLn, err := net.Listen("tcp", ":9999")
    if err != nil {
        panic(err)
    }
    // Creates instance for in memory storage
    storage := newInMemoryStorage()
    // Registrates reflection system (see below)
    reflection.Register(server)
    // Registrates storage
    proto.RegisterStorageServiceServer(server, storage)
    // Starts serving
    if err := server.Serve(grpcLn); err != nil {
        panic(err)
    }
}
```

The code is obvious and well-commented. Let me explain the reflection system. Why do we need it?
As I mentioned before, GRPC uses protobuf which is binary protocol so using all regular tools like cURL for debugging GRPC is not very comfortable. 
But we can use grpc_cli tool. For using this tool we need to register reflection service on our grpc server.
Now let's try to use our storage:
```
# Let's list all public API on the endpoint. There are two services, one for the reflection system, another is our
➜  grpc_example grpc_cli ls 127.0.0.1:9999
grpc.reflection.v1alpha.ServerReflection
tutorial.StorageService

# we see our definitions
➜  grpc_example grpc_cli ls -l 127.0.0.1:9999 tutorial.StorageService
filename: service.proto
package: tutorial;
service StorageService {
  rpc Put(tutorial.Value) returns (tutorial.Key) {}
  rpc Get(tutorial.Key) returns (tutorial.Value) {}
}

# Let's try to store something
➜  grpc_example grpc_cli call 127.0.0.1:9999 tutorial.StorageService.Put 'content: "my data"'
connecting to 127.0.0.1:9999
key: "1291e1c0aa879147f51f4a279e7c2e55"

Rpc succeeded with OK status

# Retrieve
➜  grpc_example grpc_cli call 127.0.0.1:9999 tutorial.StorageService.Get 'key: "1291e1c0aa879147f51f4a279e7c2e55"'
connecting to 127.0.0.1:9999
content: "my data"

Rpc succeeded with OK status
```


Looks like we are done with the server. Let's implement client.

About the same as for the server, we are going to start with using the generator.

- Install the generator
```
pip install grpcio-tools
```

- Modify Makefile

```
python:
    mkdir -p ${CLIENT_DST_DIR}
    touch ${CLIENT_DST_DIR}/__init__.py
    python -m grpc_tools.protoc -I=${SRC_DIR} --python_out=${CLIENT_DST_DIR} --grpc_python_out=${CLIENT_DST_DIR} ${SRC_DIR}/service.proto

```

- Create basic client


```
import grpc
import proto.service_pb2_grpc
import proto.service_pb2 as dto

if __name__ == "__main__":
    channel = grpc.insecure_channel('127.0.0.1:9999')
    client = proto.service_pb2_grpc.StorageServiceStub(channel)
    put_request= dto.Value()
    put_request.content = "My data to store!"
    response = client.Put(put_request)
    print("Value stored with key {}".format(response.key))
    print("Reading remote value for key {}".format(response.key))
    read_request = dto.Key() # Or we can just use our response instead of creating new one
    read_request.key = response.key
    read_response = client.Get(read_request)
    print("Value is {}".format(read_response.content))
```


Let's try to run it.
Don't forget to start server:

```go run server/main.go```


From another terminal:


```
➜  grpc_example python client/cli.py
Value stored with key 33216b0f4daa77fe43d674eabebc6029
Reading remote value for key 33216b0f4daa77fe43d674eabebc6029
Value is My data to store!
```

It works.

We created both client and server like in 10 minutes. 

The example located on <a href="github.com/soider/grpc_example">github</a>

Additional links:

- https://grpc.io/docs/tutorials/

- https://developers.google.com/protocol-buffers/docs/overview
