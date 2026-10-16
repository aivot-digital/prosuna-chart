# Prosuna Helm chart

The chart deploys Prosuna (API and web app) and Keycloak. PostgreSQL, RabbitMQ, Redis, ClamAV and
Gotenberg are each deployed by the chart or supplied as existing services. It is the Kubernetes
port of `examples/server/compose.yml` and `Caddyfile` in the Prosuna repository.

Resource names are fixed, so install one release per namespace. In-cluster services are addressed
by short names, so a copy in another namespace only talks to its own services.

## Install

Keep the hostname and the secrets in a local file that is never committed (`values.local*.yaml`
is ignored by git and Helm):

```yaml
# values.local.yaml
Hostname: prosuna.example.org
Secrets:
  SecretsKey: <openssl rand -hex 32>
  CaptchaKey: <openssl rand -hex 32>
  SmtpPassword: <SMTP password>
  KeycloakBootstrapAdminPassword: <at least 12 characters>
  KeycloakAdminPassword: <Keycloak password policy, see values.yaml>
  KeycloakDeploymentClientSecret: <openssl rand -hex 32>
  KeycloakBackendClientSecret: <openssl rand -hex 32>
```

Alternatively, create the Secret yourself with these keys and set `Secrets.ExistingSecret`.

```sh
helm upgrade --install testing . --namespace testing --create-namespace \
  -f examples/operator-cluster.yaml -f values.local.yaml \
  --wait --wait-for-jobs --timeout 20m
```

`examples/` has values for the supported setups:

| File                     | Setup                                                                                                      |
|--------------------------|------------------------------------------------------------------------------------------------------------|
| `operator-cluster.yaml`  | Traefik, cert-manager, CloudNativePG and RabbitMQ operators, Prometheus Operator (the k3d testing cluster) |
| `kyma.yaml`              | SAP BTP Kyma runtime with the CloudNativePG and RabbitMQ operators installed                               |
| `external-services.yaml` | Every backing service exists already; another ingress controller                                           |

## Backing services

Leave a service's `Host` empty and the chart deploys it; set `Host` to use an existing one.
`Host`, `Port`, `Secret` and `Tls` apply only to existing services.

| Service                                 | Deployed by the chart                                                                                                                                            | Existing service                                     |
|-----------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------|
| `Postgres.Prosuna`, `Postgres.Keycloak` | One CloudNativePG cluster each (`postgres-prosuna`, `postgres-keycloak`). The application reads the credentials from the generated Secret `postgres-<name>-app`. | `Host`, `Port`, `Database`, `Secret`                 |
| `Rabbitmq`                              | `RabbitmqCluster` `rabbitmq` with quorum queues. Credentials come from the generated Secret `rabbitmq-default-user`.                                             | `Host`, `Port`, `Secret`, `Tls`                      |
| `Redis`                                 | Deployment `redis` without persistence or authentication                                                                                                         | `Host`, `Port`, `Database`, optional `Secret`, `Tls` |
| `Clamav`, `Gotenberg`                   | Deployments `clamav` and `gotenberg`                                                                                                                             | `Host`, `Port`                                       |

A `Secret` for an existing service holds the keys `username` and `password`, the format of the
Secrets that CloudNativePG, the RabbitMQ operator and SAP BTP service bindings create. A binding
Secret can therefore be used directly. Otherwise create one:

```sh
kubectl -n <namespace> create secret generic prosuna-db \
  --from-literal=username=prosuna --from-literal=password='<password>'
```

Notes for existing services:

- **PostgreSQL:** create each database and its owner beforehand. Prosuna's owner must be allowed
  to create the `pg_trgm` extension, which is trusted, so database owners may create it. The JDBC
  driver uses TLS whenever the server offers it.
- **RabbitMQ:** `Tls: true` connects with TLS (usually port 5671). Set another virtual host with
  `Prosuna.ExtraEnv` and `SPRING_RABBITMQ_VIRTUAL_HOST`.
- **Redis:** the Secret is optional and needs only `password`; `username` is for ACL users.
- **Gotenberg:** Prosuna renders user-controlled HTML. An existing Gotenberg must restrict Chromium
  like `templates/gotenberg.yaml` does (`CHROMIUM_DENY_PRIVATE_IPS`, `CHROMIUM_ALLOW_LIST`).

`Prosuna.ExtraEnv` and `Keycloak.ExtraEnv` add environment variables and override the chart's
settings of the same name, e.g. `PROSUNA_SMTP_TLS`.

### RabbitMQ replicas

The chart's broker holds no state that has to survive a restart: Prosuna stores pending background
work in the database and publishes it again when the broker comes back empty. With one replica,
the default, RabbitMQ therefore runs without a volume. With more replicas, each node keeps its
data on a volume of `Rabbitmq.Storage`, because a restarted node needs it to rejoin the others.

The operator can neither add or remove the volumes of a running broker nor reduce its replicas.
To change `Rabbitmq.Replicas` from 1 to more, or to reduce it, delete the broker and its volumes
first. The new broker gets new credentials, so restart the API afterwards:

```sh
kubectl -n <namespace> delete rabbitmqcluster rabbitmq
kubectl -n <namespace> delete pvc -l app.kubernetes.io/name=rabbitmq
helm upgrade <release> . --namespace <namespace> -f <the environment's values>
kubectl -n <namespace> rollout restart deployment prosuna-api
```

## Ingress

`Ingress.Type` selects how `https://<Hostname>` reaches the workloads. All routes keep their path
prefixes: `/idp` goes to Keycloak, `/api` to the API and everything else to the web app.

- **`traefik`**: IngressRoutes that mirror the Caddyfile, including retries while the API starts
  and the `/security.txt` redirect. A standard Ingress lets cert-manager issue the certificate
  with `Ingress.ClusterIssuer`.
- **`kyma`**: one APIRule on `Ingress.Gateway`.
    - `kyma-system/kyma-gateway` serves hostnames under the cluster domain. For a custom domain, set
      up a gateway with its own certificate and DNS entry as described in Kyma's custom domain
      documentation, and set `Ingress.Gateway` to it.
    - APIRules route only to pods in the Istio service mesh. The chart therefore adds
      `sidecar.istio.io/inject: "true"` to prosuna-app, prosuna-api, keycloak and the setup Job;
      the other pods stay outside the mesh.
    - The setup Job completes only with Istio's native sidecars, the default since Istio 1.27. If
      `kubectl get job` shows the Job running after setup finished, native sidecars are off.
    - Without a CORS policy, the API Gateway removes CORS headers. The APIRule therefore allows
      GET and HEAD requests from any origin without credentials, so web fonts load cross-origin.
    - APIRules cannot redirect. `/security.txt` reaches the web app, whose redirect currently
      points to its internal `http://<Hostname>:8080/.well-known/security.txt`.
- **`none`**: route the hostname yourself and send `X-Forwarded-*` headers. Set
  `NetworkPolicy.IngressFrom` to your ingress controller's pods.

## NetworkPolicies

With `NetworkPolicy.Enabled`, each workload the chart deploys accepts connections only from the
pods that need it, mirroring the compose networks. `NetworkPolicy.IngressFrom` defaults to Traefik
pods (`traefik`) or the Istio ingress gateway in `istio-system` (`kyma`). The pods of the database
and broker clusters have no policy, because their operators and replication must reach them.

## Cluster prerequisites

The CloudNativePG and RabbitMQ operators are installed once per cluster and serve every Prosuna
release. They watch all namespaces by default; if one is restricted to certain namespaces,
include each release namespace. They are needed only for services the chart deploys.

### CloudNativePG

CloudNativePG 1.30 or newer:

```sh
kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-1.30.1.yaml
kubectl rollout status deployment -n cnpg-system cnpg-controller-manager
```

`--server-side` is required: the CRDs are too large for a client-side apply.

### Barman Cloud Plugin

Required for database backups (`Postgres.Backup.ObjectStore`). CloudNativePG's built-in backup
support is deprecated, and the chart's `standard` PostgreSQL image does not contain it. The plugin
runs next to the operator and adds a backup sidecar to each database pod.

The plugin needs CloudNativePG 1.26 or newer and cert-manager, which issues the certificates
between operator and plugin. The operator cluster has cert-manager already; on Kyma, install it
first (see [Kyma](#kyma)). The manifest installs the plugin into `cnpg-system`, the operator's
namespace, which it must share:

```sh
kubectl apply -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.15.1/manifest.yaml
kubectl rollout status deployment -n cnpg-system barman-cloud
kubectl get crd objectstores.barmancloud.cnpg.io
```

To upgrade the plugin, apply the manifest of the newer release.

### RabbitMQ Cluster Operator

```sh
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/download/v2.23.0/cluster-operator.yml
kubectl rollout status deployment -n rabbitmq-system rabbitmq-cluster-operator
```

### Kyma

The `istio` and `api-gateway` modules are enabled by default. Kyma has no cert-manager, which
the Barman Cloud Plugin needs. Kyma's own certificate management uses a different API, so the two
do not conflict. Install cert-manager first, then CloudNativePG, the Barman Cloud Plugin and the
RabbitMQ Cluster Operator as described above:

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml
kubectl rollout status deployment -n cert-manager cert-manager-webhook
```

Kyma has no Prometheus Operator, so keep `Monitoring.Enabled: false`. Clusters share egress
addresses, which quickly reach Docker Hub's anonymous pull limit; use `ImagePullSecrets` or
mirrored `Images`.

### Monitoring (optional)

`Monitoring.Enabled` creates PodMonitors for the databases and a ServiceMonitor for the broker.
This requires the Prometheus Operator CRDs, for example from kube-prometheus-stack. Their labels
come from `Monitoring.Labels` and must match the selectors of the Prometheus instance.

The operators can be scraped as well:

```sh
kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cnpg-operator-monitor
  namespace: cnpg-system
  labels:
    release: kube-prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudnative-pg
  podMetricsEndpoints:
    - port: metrics
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: rabbitmq-cluster-operator
  namespace: rabbitmq-system
  labels:
    release: kube-prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: rabbitmq-cluster-operator
  podMetricsEndpoints:
    - port: metrics
EOF
```

## Backup and restore

RabbitMQ needs no backup: Prosuna stores pending background work in the database and publishes it
again after the broker restarts, even when the broker comes back empty.

### Databases

With `Postgres.Backup.ObjectStore` set, both database clusters archive their WAL continuously
and take a base backup on `Postgres.Backup.Schedule` (daily at 02:00 UTC by default) and right
after creation. Backups are kept for `Postgres.Backup.Retention`. Each cluster writes to
`<destinationPath>/<prefix>-<database>`, where the prefix is `Postgres.Backup.Prefix` or by
default the namespace, so environments can share a bucket. A new database cluster needs a path
without earlier backups: when you reinstall into a namespace whose old backups still exist, set
another prefix, for example `testing-2`, or restore from them as described below.

`ObjectStore` is passed as is to the plugin's ObjectStore. See `examples/operator-cluster.yaml`
(S3) and `examples/kyma.yaml` (Azure Blob Storage), and the
[plugin documentation](https://cloudnative-pg.io/plugin-barman-cloud/docs/object_stores/) for
other providers. Create the credentials Secret in the release namespace first, for example for
S3:

```sh
kubectl -n <namespace> create secret generic postgres-backup-s3 \
  --from-literal=ACCESS_KEY_ID='<access key>' --from-literal=ACCESS_SECRET_KEY='<secret key>'
```

Check that archiving works and backups complete:

```sh
kubectl -n <namespace> get cluster,scheduledbackup,backup
kubectl -n <namespace> get cluster postgres-prosuna \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}'
```

### Back up now

```sh
for db in prosuna keycloak; do kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: postgres-$db-$(date +%Y%m%d%H%M%S)
  namespace: <namespace>
spec:
  cluster:
    name: postgres-$db
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
done
```

Do this after enabling backups for existing database clusters. CloudNativePG then restarts the
database pods to add the backup sidecar, and the first backup, taken right away, can fail during
that restart. Recovery needs at least one completed base backup.

### Test backups with MinIO

`dev/minio.yaml` runs a single-node MinIO with the bucket `prosuna-backups` for development
clusters. Create its credentials, deploy it and copy the credentials into the release namespace:

```sh
kubectl create namespace minio
kubectl -n minio create secret generic minio \
  --from-literal=MINIO_ROOT_USER=admin --from-literal=MINIO_ROOT_PASSWORD="$(openssl rand -hex 24)"
kubectl apply -f dev/minio.yaml
kubectl -n minio wait --for=condition=complete job/minio-bucket --timeout=180s

kubectl -n <namespace> create secret generic postgres-backup-s3 \
  --from-literal=ACCESS_KEY_ID="$(kubectl -n minio get secret minio -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d)" \
  --from-literal=ACCESS_SECRET_KEY="$(kubectl -n minio get secret minio -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)"
```

Then use the ObjectStore of `examples/operator-cluster.yaml` with
`destinationPath: s3://prosuna-backups/` and `endpointURL: http://minio.minio.svc:9000`.

### Restore

Set `Postgres.Backup.RecoverFrom` to the prefix of the backups to restore, by default the
namespace they came from. The database clusters are then created from the latest backups instead
of empty databases. Recovery happens only when a cluster is created, so restore into a new
namespace, or uninstall the release first: uninstalling deletes the database clusters, but not the
backups.

The restored clusters must not write into the backups they come from, so their own prefix has to
differ from `RecoverFrom`. Into a new namespace, the default prefix (the namespace) already
differs. Into the same namespace, set a new `Postgres.Backup.Prefix`:

```sh
# Into a new namespace
kubectl create namespace <new namespace>
kubectl -n <new namespace> create secret generic postgres-backup-s3 ...
helm upgrade --install <release> . --namespace <new namespace> \
  -f <the environment's values> --set Postgres.Backup.RecoverFrom=<old namespace>

# Into the same namespace, after helm uninstall
helm upgrade --install <release> . --namespace <namespace> -f <the environment's values> \
  --set Postgres.Backup.RecoverFrom=<namespace> --set Postgres.Backup.Prefix=<namespace>-2
```

- Keep `Prefix` and `RecoverFrom` in the environment's values afterwards. Changing `Prefix` later
  moves archiving to another path; leaving `RecoverFrom` set has no effect.
- Use the same `Secrets` as the original environment. Data encrypted with `Secrets.SecretsKey` is
  unreadable with another key.
- RabbitMQ starts empty. Prosuna continues the background work that was pending at backup time,
  because that work is stored in the database.
- Uploaded files are not part of the database backups; see below.

For a test restore next to the live environment, also use another `Hostname`, so the copy does
not take over the live routes. The copy needs as many resources as the original.

### Uploaded files

Uploaded assets and attachments live on the `prosuna-data` volume, which Helm keeps on uninstall.
The chart does not back it up. Use a volume backup outside the chart, for example Velero
file-system backups: the prosuna-api pod already requests its `data` volume with the annotation
`backup.velero.io/backup-volumes`. The database and RabbitMQ pods carry no such annotation, so
with Velero's default opt-in mode only the file storage is copied.
