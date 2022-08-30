

# k8s-deploy
for team workshop about deployments


# Connection to the eks cluster



we need to generate a kubeconfig that will help us connect to the cluster
<br > we need to have access to the API access to elliptic-platform AWS account <br >
ideally this would be via AWS SSO, but we can make static API keys work

```
❯ aws eks update-kubeconfig --region eu-west-1 --name ped-offsite

❯ kubectl get svc
NAME         TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
kubernetes   ClusterIP   172.20.0.1   <none>        443/TCP   27h

```


