# Deployment

# create a deployment

open up the deployment.yaml and fill in the values 

```
kubectl apply -f deployment.yaml &&
kubectl get deploy &&
kubectl get pods &&
sleep 1 &&
kubectl get pods
```

lets look at all the resources created in our namespace so far

```
kubectl get all
```

# replica set


let us see the replica set that has been created

```
 kubectl get rs
```
lets try deleting a pod controller by replicaset and also our pod we created previously

```
kubectl delete pod <pod_name> && 
kubectl get pod
```

# rollout

lets look at the rollout history

```
❯ kubectl rollout history deploy athiq-nginx
deployment.apps/athiq-nginx 
REVISION  CHANGE-CAUSE
1         <none>
```

lets trigger a new rollout by editing the yaml file and changing the nginx version
we will want to look at they way the roll out happend as well

```
❯ kubectl apply -f deployment.yaml && kubectl rollout status deployment athiq-nginx
❯ kubectl describe deploy athiq-nginx
```

lets look at the rollout history
```
❯ kubectl rollout history deploy athiq-nginx
deployment.apps/athiq-nginx 
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

have a look at all the resources again

```
❯ kubectl get all
```

## Rollback

```
❯ kubectl rollout undo deploy athiq-nginx && kubectl rollout status deploy athiq-nginx
```

now doing a describe of the deployment should show that the image of nginx is actually the from the previous deployment

```
❯ kubectl describe deploy athiq-nginx
```

also lets look at he revision history

```
kubectl rollout history deploy athiq-nginx
```

## Failing changes

in the deployment lets set the image tag to something that doesn't exist and see how the k8s hangles it

```
❯ kubectl apply -f deployment.yaml && kubectl rollout status deployment athiq-nginx
```

lets rollback ourcahnges

```
kubectl rollout undo deploy athiq-nginx && kubectl rollout status deploy athiq-nginx
```