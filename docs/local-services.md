# Local Services

This repository provides a local Docker environment for shared development services. Start the stack with Docker Compose before running applications that depend on it.

## Empty, Portable Installations

Use the same Compose files on Linux or inside the target WSL distribution, with Docker Engine and Compose v2 running there. The repository carries service definitions only, not application databases, stored objects, messages, credentials, or an existing Portainer configuration. A deployment with new volumes starts without application data; service-owned accounts, system databases, and the optional SQL databases are initialized normally.

On Ubuntu 22.04+ or Debian 12+ with glibc 2.35+ and x86_64 or aarch64 architecture, run `bash ./setup-local.sh --with-mysql --with-postgres --with-redis` without `--repository` to prepare all nine shared services, or omit optional flags as needed. This branch's setup also prepares its isolated PHP runtime with a controlled `ubuntu:22.04` build image; that is not a requirement of the Compose services. For a Compose-only workflow on other Linux systems, install Docker Engine and Compose v2, prepare a private `.env` from `.env.example` with fresh random passwords for all eight password variables listed in [Environment Configuration](../README.en.md#environment-configuration), set file permissions to `600`, and use the [Compose startup commands](../README.en.md#starting-the-environment). On Windows, use Docker Engine inside WSL, not a Windows-hosted container runtime.

Services are global to this local infrastructure, not duplicated per application. Published ports stay on `127.0.0.1`; applications can also use the shared Docker network. This is a local development environment, not a remotely exposed or production deployment. Do not add application containers, seeds, data dumps, or application-specific queues or buckets here. Portainer starts with its own new local administrator setup; it does not import or redeploy application stacks from another machine.

Generate credentials independently on each machine. Do not distribute a working `.env`, copy existing volumes, or export project data as part of the template. A fresh clone does not guarantee empty services if the target Docker Engine already has volumes belonging to the same Compose project. Setup reuses those volumes without clearing them. Do not run setup with newly generated credentials against existing data; recover the original private configuration first.

## Service Endpoints

| Service | Purpose | Local endpoint | Authentication |
| --- | --- | --- | --- |
| RabbitMQ | Message broker and management UI | `amqp://localhost:5672`, `http://localhost:15672` | `RABBITMQ_USERNAME` and `RABBITMQ_PASSWORD` from `.env` |
| MongoDB | Document database | `mongodb://localhost:27017` | `MONGODB_USERNAME` and `MONGODB_PASSWORD` from `.env` |
| Mongo Express | MongoDB administration UI | `http://localhost:8081` | `MONGO_EXPRESS_USERNAME` and `MONGO_EXPRESS_PASSWORD` from `.env` |
| MinIO | S3-compatible storage and console | `http://localhost:9000`, `http://localhost:9001` | `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` from `.env` |
| Mailpit | Local email capture and viewer | SMTP `localhost:1025`, `http://localhost:8025` | None |
| Portainer | Container administration UI | `http://localhost:9002`, `https://localhost:9443` | Create a local administrator on first access |
| MySQL (optional) | Relational database | `mysql://localhost:3306` | `MYSQL_USERNAME` and `MYSQL_PASSWORD` from `.env` |
| PostgreSQL (optional) | Relational database | `postgresql://localhost:5432` | `POSTGRES_USERNAME` and `POSTGRES_PASSWORD` from `.env` |
| Redis (optional) | Cache and messaging | `redis://localhost:6379` | `REDIS_PASSWORD` from `.env` |

MinIO uses the public `cgr.dev/chainguard/minio:latest` image. Its health check uses the image's Bash shell to query the live HTTP endpoint, without requiring `curl` inside the container. The existing `minio_data` volume is preserved when the container is recreated; do not run `down --volumes` just to refresh its image.

`setup-local.sh` validates Compose, starts the selected services, and waits up to 180 seconds for running or healthy status before reporting success. On failure it shows `docker compose ps` and exits nonzero; inspect `docker compose logs minio` if MinIO is the affected service. `update-local.sh` also reconciles the shared services after updating application repositories, so rerunning it applies the current MinIO image and health check. Use `--skip-services` for a Git-only update.

To prepare a new WSL installation with optional services in one run, select any combination of `--with-mysql`, `--with-postgres`, and `--with-redis` on `bash ./setup-local.sh`. Default setup starts none of them. After setup, add the corresponding `docker-compose.mysql.yml`, `docker-compose.postgres.yml`, or `docker-compose.redis.yml` files with `-f` to start them. Use the same set of Compose files for `ps`, `pull`, `down`, and `down --volumes`; the latter permanently deletes their separate volumes. Host-run applications use `localhost` and the configured ports; containers on the shared network use `mysql:3306`, `postgres:5432`, or `redis:6379`. Redis requires a password; each application owns its own SQL schema and database migrations.

When rerunning `setup-local.sh` or `update-local.sh`, repeat the flags for every optional service you want included in that Compose operation. Both scripts preserve existing named volumes.

## Persistence and Existing Installations

| Service | Named volume | Container path | Persisted state |
| --- | --- | --- | --- |
| RabbitMQ | `rabbitmq_data` | `/var/lib/rabbitmq` | Broker state; durable queues and persistent messages, subject to RabbitMQ semantics |
| MongoDB | `mongo_data` | `/data/db` | Databases and service accounts |
| Mongo Express | None | Not applicable | Stateless UI; data belongs to MongoDB |
| MinIO | `minio_data` | `/data` | Objects and storage configuration |
| Mailpit | `mailpit_data` | `/data` | Message database at `/data/mailpit.db` |
| Portainer | `portainer_data` | `/data` | Local administrator account and Portainer configuration |
| MySQL (optional) | `mysql_data` | `/var/lib/mysql` | Databases and service accounts |
| PostgreSQL (optional) | `postgres_data` | `/var/lib/postgresql/data` | Databases and service accounts |
| Redis (optional) | `redis_data` | `/data` | AOF persistence; expiration and Redis semantics still apply |

Compose prefixes these volume keys with the project name. With the supplied `COMPOSE_PROJECT_NAME=local-infrastructure`, for example, Mailpit uses `local-infrastructure_mailpit_data`. Keep the project name and volume keys stable to reuse the same local data. Changing the directory alone does not change this explicit project name; changing `.env`, `-p`, or the project name in Portainer can select different volumes. This can make services appear empty without deleting their previous data. Do not rename or delete old volumes to troubleshoot that situation.

`docker compose up -d`, container recreation, and `docker compose down` without `--volumes` retain named volumes. Use all selected optional `-f` files for each operation. **`down --volumes` and volume pruning can permanently delete local data**; they are not normal update steps or prerequisites for installing on another machine. Volumes stay on the local Docker Engine and do not travel with a Git clone. They are persistence, not backups or a guarantee against application deletions or storage failure.

### RabbitMQ identity

New deployments use a stable hostname, `RABBITMQ_HOSTNAME=rabbitmq`, so recreating the container does not change the default RabbitMQ node identity or its data directory. The Compose fallback is also `rabbitmq` if that variable is absent. Keep this value unchanged while reusing `rabbitmq_data`.

An older container may have used a Docker-generated hostname. Before applying this configuration, recover that previous hostname locally and set `RABBITMQ_HOSTNAME` to it in the private `.env`. Otherwise, RabbitMQ may select a different node data directory inside the same volume and appear to have lost queues or users. If the older installation used a custom node name, plan a separate supported migration; setting the hostname alone does not migrate it. Do not regenerate credentials, change node identities, or manipulate data directories as an automatic upgrade step.

### Mailpit storage

`MP_DATABASE=/data/mailpit.db` places Mailpit's SQLite database in `mailpit_data`. This retains captured mail across container recreation. Message retention still applies: Mailpit defaults to keeping up to 500 messages; persistence does not disable retention or deletion from the UI. See the [Mailpit Docker documentation](https://mailpit.axllent.org/docs/install/docker/) and [runtime options](https://mailpit.axllent.org/docs/configuration/runtime-options/).

The older configuration had neither this volume nor an explicit database path. Adding a volume does not migrate its temporary database. If existing mail is needed, save or migrate it locally before stopping or recreating that container, keeping exports private and outside this repository. Do not apply setup, update, or `up --force-recreate` to an older installation until these RabbitMQ and Mailpit precautions have been addressed.

Portainer's volume preserves Portainer itself; it is not a backup of the other services' volumes. None of these changes requires exporting or copying the current Docker Engine's databases, stacks, or credentials.

## Service Use

- Configure applications with environment variables; do not commit local connection values or credentials.
- Use service names and internal ports when an application runs on the shared Docker network.
- Use `localhost` and published ports when an application runs on the host.
- Keep application data in the service volumes above; back up any local data that must survive host loss or an intentional reset.
- The generated credentials belong only to local development. Do not print or share `.env` values.

Portainer stores its administrator account in its Docker volume. Resetting volumes removes this account and all other local service data.

## Operations

Use Docker Compose to start, stop, inspect, and refresh the local stack. Check container health and logs before diagnosing application-level connection failures.
