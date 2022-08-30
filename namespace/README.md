# Creating the namesapce 



create our own namespace by editing the namespace.yaml file and entering whatever we want.
then we apply as follows
```
❯ kubectl apply -f namespace.yaml
namespace/athiq created
```

by default, all commands go to default namespace, so lets change that to the namespace we created
```
❯ kubectl get namespace

❯ kubectl config set-context --current --namespace=athiq
```
