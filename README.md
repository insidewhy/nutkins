# Nutkins

[![build status](https://circleci.com/gh/ohjames/nutkins.png)](https://circleci.com/gh/ohjames/nutkins)

Nutkins is a tool to manage and test a repository containing one or more docker images.
 * Easy to create and run test instances of any service in a single command.
 * Docker images and containers are managed to avoid the difficulties using the raw `docker` command provides around removing images.
 * A wrapper around `fleetctl` to make upgrading services easy.
 * Extra configuation in `nutkins.yaml` and `nutkin.yaml` to add extra functionality missing from docker.
