# k8s-deploy
for team workshop about deployments

## Connection to the eks cluster

we need to generate a kubeconfig that will help us connect to the cluster

```
❯ aws eks update-kubeconfig --region eu-west-1 --name ped-offiste

❯ kubectl get svc
NAME         TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
kubernetes   ClusterIP   172.20.0.1   <none>        443/TCP   27h

```
## creating the namesapce 

create our own namespace by editing the namespace.yaml file and entering our name
```
❯ kubectl apply -f namespace.yaml
```

by default, all commands go to default namespace, so lets change our that to the namespace we created
```
❯ kubectl get namespace
kubectl config set-context --current --namespace=athiq
```

## creatin pod 

We will create the pod running nginx container

```
❯ kubectl apply -f pod.yaml
❯ kubectl apply -f pod.yaml && kubectl get pods
pod/nginx created
NAME    READY   STATUS              RESTARTS   AGE
nginx   0/1     ContainerCreating   0          1s

❯ kubectl get pods
NAME    READY   STATUS    RESTARTS   AGE
nginx   1/1     Running   0          56s

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

now you can open up a new terminal try to curl

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