# New VPS Server Setup

## Introduction
This manual describes the process of setting up a new VPS server for running containerized applications.

## Prerequisites
It is assumed that:
- The VPS server is ordered and has the SSH access enabled. 
- The server has linux/debian installed with the kernel version >= 4
- The server has at least 2 GB of memory and 1 CPU

## Installation

### Update the System
1. Run system update: `apt update && apt upgrade`
2. Reboot the system: `reboot`

### Install Needed Sortware
1. Install the ufw firewall: `apt install ufw`

### Create Dedicated User
In order not to abuse the root access a separate user has to be created. 

1. Create a user: `adduser nikita`
2. Make it a sudoer: `usermod -aG sudo nikita`

Afterwards login as the newly created user.

### Configure Wireguard
Wireguard is a fast and efficient VPN protocol. It is better to access the server over the VPN to protect it. For that we need to create a Wireguard server and register some clients with it.

1. Install wireguard:
`sudo apt update && sudo apt install wireguard`
2. Generate a private key for your server: `wg genkey`
3. Create a config file `/etc/wireguard/wg0.conf` with the following content:
    ```
    [Interface]
    PrivateKey = <Key generated on step2>
    Address = 192.168.2.1/32
    ListenPort = 51820
    ```
4. Run the wireguard server as a service by issuing the following commands: `sudo systemctl enable wg-quick@wg0 && sudo systemctl start wg-quick@wg0`
5. Make sure the server is up: `sudo wg`
6. Install Wireguard on the client (client specific), obtain client public key.
7. Configure the client:
    ```
    [Interface]
    PrivateKey = <....>
    Address = 192.168.2.2/32

    [Peer]
    PublicKey = <Server public key visible on step 5> 
    AllowedIPs = 192.168.2.1/32
    Endpoint = <your_server_ip>:51820
    PersistentKeepalive = 25
    ```
8. Edit `/etc/wireguard/wg0.conf` on the server and add the following section:
    ```
    [Peer]
    PublicKey = <Public key of the client>
    AllowedIPs = 192.168.2.2/32
    ```
9. Connect the client to the server (client specific) and test the connection by sending pings from the client: `ping 192.168.2.1`
10. To allow clients see each other add the following 2 lines to /etc/sysctl.conf
    ```
    net.ipv4.ip_forward = 1
    net.ipv4.conf.all.proxy_arp = 1
    ```
    and then run `sudo sysctl -p /etc/sysctl.conf`

### Set Up microk8s
microk8s is a lightweight implementation of kubernetes. It will allow us to run containerized applications on our server.

1. Install microk8s: `sudo snap install microk8s --classic`
2. Install add-ons: `sudo microk8s enable ingress dns registry`
3. Check the installation: `sudo microk8s kubectl describe node`

### Configure Access to microk8s Registry

microk8s comes with its own registry that is listening on the port `32000`. This registry is unprotected therefore it needs to be accessed over the VPN connection and secured by the firewall from the outside world. The firewall will be configured later in this instruction.

To be able to push to an unprotected repository you have to configure exceptions in `insecure-registries`. This step is platform-specific. 
- Colima: edit `~/.colima/default/colima.yaml` and add the following:
    ```
    docker:
        insecure-registries:
            - 192.168.2.1:32000
    ```
- Docker: edit `/etc/docker/daemon.json` and add the following:
    ```
    {
        "insecure-registries" : ["192.168.2.1:32000"]
    }
    ```
After that restart Colima/Docker.

Now you can build and push images to your remote repository:
```
docker build -t 192.168.2.1:32000/yourapp .
docker push 192.168.2.1:32000/yourapp
```

### Install kubectl
To be able to manage your kubernetes installation you need to install and configure the `kubectl` utility:

1. Follow the installation instructions here: https://kubernetes.io/docs/tasks/tools/
2. On the server side run `sudo microk8s config`
3. Copy the output results into ~/.kube/config
4. Test the connection by running `kubectl describe node`

### Protect Server with Firewall
microk8s uses iptables to set up its network, This makes blocking some of the ports challenging as the packets are NAT'ed before they hit filtering. This means, for example, that the incoming packets to the registry that come to the port 32000 will get their port changed before they reach any filtering rules.

The fact that on your specific server microk8s can use both nft and legacy iptables further complicates the setup. 
To solve this problem a special watcher service is used that corrects the iptables blocking access to the needed potrs after microk8s starts up.

1. Copy `wait-for-it.sh` and `iptables-watcher.sh` to `/usr/local/bin/`
2. Copy `iptables-watcher.service` to `/etc/systemd/system/`
3. Start the service: `sudo systemctl start iptables-watcher`
4. Enable the service on startup: `sudo systemctl enable iptables-watcher`
5. Make sure the port 32000 is not reachable from the public IP.

The rest of the setup is easier done with the ufw tool that under the hoos also works with iptanles:
1. Enable ssh access to the server: `sudo ufw allow 22`
2. Enable access to Wireguard server: `sudo ufw allow 51820`
3. Enable kubectl access to microk8s: `sudo ufw allow from 192.168.2.0/24 to 192.168.2.1 port 16443`
4. Enable the firewall: `sudo ufw enable`
5. Check that connections can be established.

### Final Test of the Installation

The set up shall be complete. You can try deploying to your kubernetes cluster from your client kubectl utility.

## Configure SSL
First you need to install cert-manager
```
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.9.1/cert-manager.yaml
```

The next command should show 3 pods to confirm cert-manager is installed and running
```
kubectl get pods -n=cert-manager
```

Apply both issuer configs
```
kubectl apply -f letsencrypt/letsencrypt-staging.yaml
kubectl apply -f letsencrypt/letsencrypt-prod.yaml
```

Update ingress to use the staging certificate like so
```
apiVersion: networking.k8s.io/v1beta1
kind: Ingress
metadata:
  name: ingress-routes
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-staging"
spec:
  tls:
  - hosts:
#change to your domain
    - yourdomain.com
    secretName: tls-secret
  rules:
#change to your domain
  - host: yourdomain.com
    http:
      paths:
        - path: /
        pathType: Prefix
        backend:
          service:
            name: webserver-svc
            port:
              number: 80
```

Run the next command to confirm Ready=True
```
kubectl get certificate
```

If it returned true, that means HTTP-01 challenge was successful. You can see more detail at the end of output running the next command
```
kubectl describe certificate tls-secret
```

Now to change the ingress to use the production certificate.
```
cert-manager.io/cluster-issuer: "letsencrypt-prod"
```

Run the next command to confirm a certificate was generated. Ready=True
```
kubectl get certificate
```
