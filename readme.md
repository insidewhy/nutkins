# Nutkins

[![build status](https://circleci.com/gh/ohjames/nutkins.png)](https://circleci.com/gh/ohjames/nutkins)

nutkins provides a way to build and test clusters based on one or more containers.
 * A easier and more flexible way to build docker images than `Dockerfile`.
   * Can run multiple commands to build a layer with comments for each.
   * No need for `.dockerignore`.
   * Caches each command in a layer and rebuilds from cache in a fraction of a second.
 * Test services that use multiple containers without having to use VMs.
 * Support for etcd/environment variables and confd.
  * nutkins will run a local etcd server for your tests.
  * nutkins will build confd configuration files for you using a sensible convention-over-configuration approach.
 * Manages secrets encrypted with gpg.

nutkins works great with:
 * [smell-baron](https://github.com/ohjames/smell-baron) - an init system for docker containers
 * [etcd](https://github.com/coreos/etcd) - a distributed key-value data store.
 * [confd](https://github.com/kelseyhightower/confd) - a system for building configuration files from data stored using `etcd` (and other data stores).

## installation

```bash
gem install nutkins
```

## configuring nutkins

### The project root

In the project root there should be a `nutkins.yaml` which may contain global configuration:

```yaml
version: 0.0.1
repository: myorg
```

With this configuration each built image will be tagged `myorg/${image_name}:0.0.1` where `0.0.1` may also be overridden per image.

For projects that consist of a single `nutkin.yaml` in the project root then `nutkins.yaml` may be omitted and these fields should be present in the `nutkin.yaml`.

### Images

Each subdirectory in the project root that contains a file `nutkin.yaml` is used to build a docker image. The following project contains an image in a subdirectory `base` that extends the ubuntu:16.04 container hosted on docker hub:

```yaml
base: ubuntu:16.04

build:
  resources:
    -
      source: https://github.com/ohjames/smell-baron/releases/download/v0.3.1/smell-baron
      dest: bin/smell-baron
      mode: 0755
    -
      source: https://github.com/kelseyhightower/confd/releases/download/v0.12.0-alpha3/confd-0.12.0-alpha3-linux-amd64
      dest: bin/confd
      mode: 0755
    -
      source: https://github.com/coreos/etcd/releases/download/v3.0.6/etcd-v3.0.6-linux-amd64.tar.gz
      extract: "*/etcdctl"
      dest: bin/etcdctl
      mode: 0755
  commands:
    - run:
      - apt-get update
      - apt-get install -y vim zsh less nano rsync git net-tools
      - groupadd -g 5496 sslcerts
    - add: bin/* /bin/
    - entrypoint: ["/bin/smell-baron"]
```

The `resources` section downloads files to local directories so that they can be used in the image. In the case of `confd` it also extracts a file from a `tar.gz` compressed archive.

The `commands` section is like a `Dockerfile` and is used to build a container. In this case it runs multiple commands, add some files to the image and sets an `entrypoint`. This image would be tagged `myorg/base:0.0.1`. The image name comes from the subdirectory but can be overriden along with the `version`:

```yaml
base: ubuntu:16.04
image: base_image
version: 0.0.2
build:
  # ... as before
```

To build this image:
```
nutkins build base
```

To run a container from this image (this also rebuilds the image which is very fast due to `nutkins` cache usage):
```
nutkins run base
```

To run a container from this image and open an interactive shell (this only works if the `entrypoint` is [smell-baron](https://github.com/ohjames/smell-baron)):
```
nutkins run -s base
```

### Image project dependencies

When a `nutkin.yaml` file refers to a `base` image that exists in the current project then `nutkins` ensures the base image is up to date before any images are built that use or extend it.

### Sharing local data with images

When using `nutkins` to test images it can be useful to share data in the host system with the running containers:

```yaml
base: base

build:
  commands:
    # ... build commands go here
create:
  volumes:
    - ssl -> /etc/ssl
    - ejabberd-etc -> /tmp/ejabberd-etc
    - ejabberd-var -> /var/lib/ejabberd
```

If `nutkins.yaml` is in the directory `subdir` the volume `ssl` will be searched for first in `subdir/volumes/ssl` and then `volumes/ssl`.

### Sharing ports with the host operating system

```yaml
create:
  ports:
    - 5222
    - 5269
```

### Testing images configured with etcd

The following `nutkin.yaml` shows how to share data via `etcd`:

```yaml
base: base

build:
  commands:
    # ... as before
create:
  # ... as before
etcd:
  data:
    ejabberd/node_name: ejabberd@myhost
    ejabberd/hostname: myhost.net
    ejabberd/muc_host: c.@HOST@
```

When running any container in the project `nutkins` will first start up a container running `etcd` and store the etcd data from every `nutkin.yaml` in it. To access this `etcd` data from within the container:

```bash
etcd2_host=$(ip route | grep '^default' | cut -d' ' -f3)
# use confd to build the configuration files from the data stored in etcd
confd -onetime -backend etcd -node http://$etcd_host:2379
```

The same command will work within a CoreOS cluster or any other etcd backed cluster.
