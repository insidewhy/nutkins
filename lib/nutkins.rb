require "yaml"
require "ostruct"
require "net/http"
require "uri"
require "fileutils"
require "json"
require "net/http"

module Nutkins ; end

require "nutkins/docker"
require "nutkins/docker_builder"
require "nutkins/download"
require "nutkins/version"

require_relative "hash_dig"

# throughout this file "path" is a directory, it should be "." or a single path like "directory"
# which should correspond to a directory within the project root containing a nutkin.yaml

# Must be somedomain.net instead of somedomain.net/, otherwise, it will throw exception.
module Nutkins
  CONFIG_FILE_NAME = 'nutkins.yaml'
  IMG_CONFIG_FILE_NAME = 'nutkin.yaml'
  VOLUMES_PATH = 'volumes'
  ETCD_PORT = 2379

  class CloudManager
    def initialize(project_dir: nil)
      @img_configs = {}
      # when an image is built true is stored against it's name to avoid building it again
      @built = {}
      @etcd_running = false
      @project_root = project_dir || Dir.pwd
      cfg_path = File.join(@project_root, CONFIG_FILE_NAME)
      if File.exists? cfg_path
        @config = OpenStruct.new(YAML.load_file cfg_path)
      else
        @config = OpenStruct.new
      end
    end

    def build path
      cfg = get_image_config path
      img_dir = cfg['directory']
      img_name = cfg['image']
      return if @built[img_name]

      raise "directory `#{img_dir}' does not exist" unless Dir.exists? img_dir
      tag = cfg['tag']

      # TODO: flag to suppress building base image?
      base = cfg['base']
      unless @built[base]
        base_cfg = config_for_image base
        if base_cfg
          base_path = base_cfg['path']
          puts "building parent of #{img_name}: #{base}"
          build base_path
        end
      end
      prev_image_id = Docker.image_id_for_tag tag

      build_cfg = cfg["build"]
      if build_cfg
        # download each of the files in the resources section if it doesn't exist
        resources = build_cfg["resources"]
        Download.download_resources img_dir, resources if resources
      end

      if cfg.dig "build", "commands"
        # if build commands are available use nutkins built-in builder
        base_cfg ||= config_for_image base
        Docker::Builder::build cfg, base_cfg && base_cfg['tag']
      else
        # fallback to `docker build` which is less good
        if not Docker.run 'build', '-t', cfg['latest_tag'], '-t', tag, img_dir, stdout: true
          raise "issue building docker image for #{path}"
        end
      end

      image_id = Docker.image_id_for_tag tag
      if prev_image_id
        if image_id != prev_image_id
          puts "deleting previous image #{prev_image_id}"
          Docker.run "rmi", prev_image_id
        else
          puts "unchanged image: #{tag}"
        end
      elsif image_id
        puts "created new image #{image_id}"
      else
        puts "no image exists for image... what went wrong?"
      end
      @built[img_name] = true
    end

    def create path, preserve: false, docker_args: [], reuse: false
      flags = []
      cfg = get_image_config path
      create_cfg = cfg["create"]
      if create_cfg
        (create_cfg["ports"] or []).each do |port|
          flags.push '-p', "#{port}:#{port}"
        end

        img_dir = cfg['directory']
        (create_cfg["volumes"] or []).each do |volume|
          src, dest = volume.split ' -> '
          src_dir = File.absolute_path File.join(img_dir, VOLUMES_PATH, src)
          unless Dir.exists? src_dir
            src_dir = File.absolute_path File.join(@project_root, VOLUMES_PATH, src)
            raise "could not find source directory for volume #{src}" unless Dir.exists? src_dir
          end
          flags.push '-v', "#{src_dir}:#{dest}"
        end

        (create_cfg["env"] or {}).each do |name, val|
          flags.push '-e', "#{name}=#{val}"
        end

        hostname = create_cfg['hostname']
        flags.push '-h', hostname if hostname
      end

      tag = cfg['tag']
      prev_container_id = Docker.container_id_for_tag tag unless preserve

      if not reuse
        if prev_container_id
          puts "deleting previous container #{prev_container_id}"
          Docker.run "rm", prev_container_id
          prev_container_id = nil
        end
        build path
      end

      puts "creating new docker image"
      unless Docker.run "create", "-it", *flags, tag, *docker_args
        raise "failed to create `#{path}' container"
      end

      unless preserve
        container_id = Docker.container_id_for_tag tag
        if not prev_container_id.nil? and container_id != prev_container_id
          puts "deleting previous container #{prev_container_id}"
          Docker.run "rm", prev_container_id
        end
      end

      puts "created `#{path}' container"
    end

    def run path, reuse: false, shell: false
      cfg = get_image_config path
      tag = cfg['tag']

      start_etcd_container if cfg['etcd']
      create_args = []
      if shell
        raise '--shell and --reuse arguments are incompatible' if reuse

        # TODO: fix crash when image doesn't exist yet... the tag isn't
        #       there to be inspected yet
        # TODO: test for smell-baron
        create_args = JSON.parse(`docker inspect #{tag}`)[0]["Config"]["Cmd"]

        kill_everything = create_args[0] == '-a'
        create_args.shift if kill_everything

        create_args.unshift '/bin/bash', '---'
        create_args.unshift '-f' unless create_args[0] == '-f'
        create_args.unshift '-a' if kill_everything
        # TODO: provide version that doesn't require smell-baron
      end

      id = reuse && Docker.container_id_for_tag(tag)
      unless id
        create path, docker_args: create_args
        id = Docker.container_id_for_tag tag
        raise "couldn't create container to run `#{path}'" unless id
      end

      Kernel.exec "docker", "start", "-ai", id
    end

    def delete path
      cfg = get_image_config path
      tag = cfg['tag']
      container_id = Docker.container_id_for_tag tag
      raise "no container to delete" if container_id.nil?
      puts "deleting container #{container_id}"
      Docker.run "rm", container_id
    end

    def delete_all
      puts "TODO: delete_all"
    end

    def build_secret path
      secret = path
      path_is_dir = Dir.exists? path
      if path_is_dir
        secret += '.tar'
        system "tar", "cf", secret, "-C", File.dirname(path), File.basename(path)
      end

      loop do
        puts "enter passphrase for #{secret}"
        break if system 'gpg', '-c', secret
      end

      File.unlink secret if path_is_dir
    end

    def extract_secrets paths
      if paths.empty?
        paths = get_all_img_paths
        # there may be secrets in the root even if there is no image build there
        paths.push '.' unless paths.include? '.'
      end

      paths.each do |path|
        get_secrets(path).each do |secret|
          loop do
            puts "enter passphrase for #{secret}"
            break if system 'gpg', secret
          end

          secret = secret[0..-5]
          if File.extname(secret) == '.tar'
            system "tar", "xf", secret, "-C", File.dirname(secret)
            File.unlink secret
          end
        end
      end
    end

    def exec path, *cmd
      puts "TODO: exec #{path}: #{cmd.join ' '}"
    end

    def start_etcd_container
      return if @etcd_running
      # TODO: move this stuff into another file
      name = get_etcd_container_name
      return unless name

      # TODO: update existing etcd server rather than creating new container...
      #       this will let confd instances respond to updates
      existing = Docker.container_id_for_name name
      if existing
        Docker.run 'stop', name
        rm_etcd_docker_container existing
      end

      gateway = Docker.run_get_stdout 'run', '--rm=true',
                 'quay.io/coreos/etcd',
                 'sh', '-c',
                 "route -n | grep UG | awk '{ print $2 }'"

      Docker.run 'create', '--name', name, '-p', "#{ETCD_PORT}:#{ETCD_PORT}",
                 'quay.io/coreos/etcd',
                 'etcd', '-name', name,
                 '-advertise-client-urls', "http://#{gateway}:#{ETCD_PORT}",
                 '-listen-client-urls', "http://0.0.0.0:#{ETCD_PORT}"

      all_paths = get_all_img_paths
      configs = all_paths.map &method(:get_image_config)
      etcd_store = {}
      configs.each do |config|
        etcd_store.merge! config['etcd']['data'] if config.dig('etcd', 'data')

        etcd_files = config.dig('etcd', 'files')
        if etcd_files
          etcd_files.each do |file|
            etcd_data_path = File.join config['directory'], file
            begin
              etcd_store.merge! YAML.load_file(etcd_data_path)
            rescue => e
              puts "failed to load etcd data file: #{etcd_data_path}"
              puts e
            end
          end
        end
      end

      if Docker.run 'start', name
        puts 'started etcd container'
        # even after port is open it still refuses http requests for a while
        # so just sleep until it is ready... ideally test for working HTTP
        sleep 1

        etcd_store.each do |key, val|
          uri = URI("http://127.0.0.1:#{ETCD_PORT}/v2/keys/#{key}")
          req = Net::HTTP::Put.new(uri)
          req.body = 'value=' + val
          res = Net::HTTP.start(uri.hostname, uri.port) do |http|
            http.request(req)
          end

          if not res.is_a? Net::HTTPCreated
            puts "etcd: failed to set #{key} to #{val}"
            puts res
          end
        end
        @etcd_running = true
      else
        puts 'failed to start etcd container'
      end
    end

    def stop_etcd_container
      name = get_etcd_container_name
      return unless name

      existing = Docker.container_id_for_name name
      if existing
        if Docker.run 'stop', name
          puts 'stopped etcd container'
          rm_etcd_docker_container existing
        else
          puts 'failed to stop etcd container'
        end
      end
    end

  private
    def get_etcd_container_name; "nutkins-etcd"; end

    # path should be "." or a single element path referencing the project root
    def get_image_config path
      cached = @img_configs[path]
      return cached if cached

      directory =  get_project_dir(path)
      img_cfg_path = File.join directory, IMG_CONFIG_FILE_NAME
      raise "missing #{img_cfg_path}" unless File.exists?(img_cfg_path)
      img_cfg = YAML.load_file(img_cfg_path)
      img_cfg['image'] ||= path if path != '.'
      img_cfg['path'] = path
      raise "#{img_cfg_path} must contain `image' entry" unless img_cfg['image']

      img_cfg['shell'] ||= '/bin/sh'
      img_cfg['directory'] = directory
      img_cfg["version"] ||= @config.version if @config.version
      img_cfg['version'] = img_cfg['version'].to_s
      raise "#{img_cfg_path} must contain `version' entry" unless img_cfg.has_key? 'version'
      img_cfg['latest_tag'] = get_tag img_cfg
      img_cfg['tag'] = img_cfg['latest_tag'] + ':' + img_cfg['version']

      # base isn't the full tag name in the case of local references!!
      base = img_cfg['base']
      raise "#{img_cfg_path} must include `base' field" unless base
      @img_configs[path] = img_cfg
    end

    def get_project_dir path
      path == '.' ? @project_root : File.join(@project_root, path)
    end

    def get_tag img_cfg
      repository = img_cfg['repository'] || @config.repository
      if repository.nil?
        raise "nutkins.yaml or nutkin.yaml should contain `repository' entry for this command"
      end
      repository + '/' + img_cfg['image']
    end

    def get_all_img_paths
      Dir.glob("#{@project_root}{,/*}/nutkin.yaml").map do |path|
        File.basename File.dirname(path)
      end
    end

    def config_for_image image_name
      get_all_img_paths.map(&method(:get_image_config)).find do |cfg|
        cfg['image'] == image_name
      end
    end

    def get_secrets path
      Dir.glob("#{path}/{volumes,secrets}/*.gpg")
    end

    def rm_etcd_docker_container existing
      raise 'could not delete existing container' unless Docker.run 'rm', existing if existing
    end
  end
end
