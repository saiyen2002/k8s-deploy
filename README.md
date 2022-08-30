# k8s-deploy
for team workshop about deployments

<span style="color:green;font-weight:700;font-size:20px"> 
Connection to the eks cluster
</span>


we need to generate a kubeconfig that will help us connect to the cluster
<br > we need to have access to the API access to elliptic-platform AWS account <br >
ideally this would be via AWS SSO, but we can make static API keys work

```
❯ aws eks update-kubeconfig --region eu-west-1 --name ped-offsite

❯ kubectl get svc
NAME         TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
kubernetes   ClusterIP   172.20.0.1   <none>        443/TCP   27h

```
<span style="color:green;font-weight:700;font-size:20px"> 
Creating the namesapce 
</span>


create our own namespace by editing the namespace.yaml file and entering whatever we want.
then we apply as follows
```
❯ kubectl apply -f namespace.yaml
```

by default, all commands go to default namespace, so lets change our that to the namespace we created
```
❯ kubectl get namespace
namespace/athiq created
❯ kubectl config set-context --current --namespace=athiq
```

<span style="color:green;font-weight:700;font-size:20px"> 
Creating the pod
</span>

We will create the pod running nginx container

```
❯ kubectl apply -f pod.yaml && kubectl get pods
pod/nginx created
NAME    READY   STATUS              RESTARTS   AGE
nginx   0/1     ContainerCreating   0          1s

❯ kubectl get pods
NAME    READY   STATUS    RESTARTS   AGE
nginx   1/1     Running   0          56s

```
<span style="color:green;font-weight:700;font-size:20px"> 
Common pod commands
</span>


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


