# Nutkins

[![build status](https://circleci.com/gh/ohjames/nutkins.png)](https://circleci.com/gh/ohjames/nutkins)

Nutkins is a tool to manage and test a CoreOS cluster:
 * Config for each service is stored in a directory including an optional `config.yaml` and a `Dockerfile`.
 * Easy to create and run test instances of any service in a single command.
 * Docker images and containers are managed to avoid the difficulties using the raw `docker` command provides around removing images.
 * A wrapper around [sistero](https://github.com/ohjames/sistero), a profile based cluster management tool is provided to make adding new instances to a cluster trivial (currently only digital ocean is supported).
 * A wrapper around `fleetctl` to make upgrading services easy.
