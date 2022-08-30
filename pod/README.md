# Creating the pod

edit pod.yaml file with the desired configuration

We will create a pod running nginx container

```
❯ kubectl apply -f pod.yaml && kubectl get pods
pod/nginx created
NAME    READY   STATUS              RESTARTS   AGE
nginx   0/1     ContainerCreating   0          1s

❯ kubectl get pods
NAME    READY   STATUS    RESTARTS   AGE
nginx   1/1     Running   0          56s

```

## Common pod commands



describe the pod that is deployed

```
kubectl describe pod nginx
```

The pod only exists inside the cluster and is not exposed to the outside world. <br >
we can access it by setting up a proxy and curl to it

```
❯ kubectl port-forward pod/nginx 8080:80
Forwarding from 127.0.0.1:8080 -> 80
Forwarding from [::1]:8080 -> 80
Handling connection for 8080
Handling connection for 8080
```

now you can open up a new terminal try to curl, or on your browser go to 127.0.0.1:8080

```
❯ curl -I localhost:8080
HTTP/1.1 200 OK
Server: nginx/1.23.0
Date: Tue, 30 Aug 2022 12:51:06 GMT
Content-Type: text/html
Content-Length: 615
Last-Modified: Tue, 21 Jun 2022 14:25:37 GMT
Connection: keep-alive
ETag: "62b1d4e1-267"
Accept-Ranges: bytes
```

how to log into the pod shell

```
kubectl exec -it nginx -- /bin/sh
```

how to get pod logs 

```
kubectl logs nginx
```