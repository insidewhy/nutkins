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

# Must be somedomain.net instead of somedomain.net/, otherwise, it will throw exception.
module Nutkins
  CONFIG_FILE_NAME = 'nutkins.yaml'
  IMG_CONFIG_FILE_NAME = 'nutkin.yaml'
  VOLUMES_PATH = 'volumes'
  ETCD_PORT = 2379

  class CloudManager
    def initialize(project_dir: nil)
      @project_root = project_dir || Dir.pwd
      cfg_path = File.join(@project_root, CONFIG_FILE_NAME)
      if File.exists? cfg_path
        @config = OpenStruct.new(YAML.load_file cfg_path)
      else
        @config = OpenStruct.new
      end
    end

    def build img_name
      cfg = get_image_config img_name
      img_dir = get_project_dir img_name
      raise "directory `#{img_dir}' does not exist" unless Dir.exists? img_dir
      tag = cfg['tag']

      prev_image_id = Docker.image_id_for_tag tag

      build_cfg = cfg["build"]
      if build_cfg
        # download each of the files in the resources section if it doesn't exist
        resources = build_cfg["resources"]
        Download.download_resources img_dir, resources if resources
      end

      if cfg.dig "build", "commands"
        # if build commands are available use nutkins built-in builder
        DockerBuilder::build cfg
      else
        # fallback to `docker build` which is less good
        if not Docker.run 'build', '-t', cfg['latest_tag'], '-t', tag, img_dir, stdout: true
          raise "issue building docker image for #{img_name}"
        end
      end

      image_id = Docker.image_id_for_tag tag
      if prev_image_id
        if image_id != prev_image_id
          puts "deleting previous image #{prev_image_id}"
          Docker.run "rmi", prev_image_id
        else
          puts "image is identical to cached version"
        end
      elsif image_id
        puts "created new image #{image_id}"
      else
        puts "no image exists for image... what went wrong?"
      end
    end

    def create img_name, preserve: false, docker_args: [], reuse: false
      flags = []
      cfg = get_image_config img_name
      create_cfg = cfg["create"]
      if create_cfg
        (create_cfg["ports"] or []).each do |port|
          flags.push '-p', "#{port}:#{port}"
        end

        img_dir = get_project_dir img_name
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
        build img_name
      end

      puts "creating new docker image"
      unless Docker.run "create", "-it", *flags, tag, *docker_args
        raise "failed to create `#{img_name}' container"
      end

      unless preserve
        container_id = Docker.container_id_for_tag tag
        if not prev_container_id.nil? and container_id != prev_container_id
          puts "deleting previous container #{prev_container_id}"
          Docker.run "rm", prev_container_id
        end
      end

      puts "created `#{img_name}' container"
    end

    def run img_name, reuse: false, shell: false
      cfg = get_image_config img_name
      tag = cfg['tag']
      create_args = []
      if shell
        raise '--shell and --reuse arguments are incompatible' if reuse

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
        create img_name, docker_args: create_args
        id = Docker.container_id_for_tag tag
        raise "couldn't create container to run `#{img_name}'" unless id
      end

      Kernel.exec "docker", "start", "-ai", id
    end

    def delete img_name
      cfg = get_image_config img_name
      tag = cfg['tag']
      container_id = Docker.container_id_for_tag tag
      raise "no container to delete" if container_id.nil?
      puts "deleting container #{container_id}"
      # TODO: also delete :latest
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

    def extract_secrets img_names
      if img_names.empty?
        img_names = get_all_img_names(img_names).push '.'
      end

      img_names.each do |img_name|
        get_secrets(img_name).each do |secret|
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

    def exec img_name, *cmd
      puts "TODO: exec #{img_name}: #{cmd.join ' '}"
    end

    def start_etcd_container
      name = get_etcd_container_name
      return unless name

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

      img_names = get_all_img_names(img_names)
      configs = img_names.map &method(:get_image_config)
      etcd_store = {}
      configs.each do |config|
        etcd_store.merge! config['etcd']['data'] if config.dig('etcd', 'data')

        if config.dig('etcd', 'files')
          config['etcd']['files'].each do |file|
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
    def get_etcd_container_name
      repository = @config.repository
      repository && "nutkins-etcd-#{repository}"
    end

    def get_image_config path
      directory =  get_project_dir(path)
      img_cfg_path = File.join directory, IMG_CONFIG_FILE_NAME
      img_cfg = File.exists?(img_cfg_path) ? YAML.load_file(img_cfg_path) : {}
      img_cfg['image'] ||= path if path != '.'
      img_cfg['shell'] ||= '/bin/sh'
      img_cfg['directory'] = directory
      img_cfg["version"] ||= @config.version if @config.version
      img_cfg['version'] = img_cfg['version'].to_s
      raise 'missing mandatory version field' unless img_cfg.has_key? 'version'
      img_cfg['latest_tag'] = get_tag img_cfg
      img_cfg['tag'] = img_cfg['latest_tag'] + ':' + img_cfg['version']
      img_cfg
    end

    def get_project_dir path
      path == '.' ? @project_root : File.join(@project_root, path)
    end

    def get_tag img_cfg
      unless img_cfg.has_key? "image"
        raise "nutkins.yaml should contain `image' entry for this command"
      end

      repository = img_cfg['repository'] || @config.repository
      if repository.nil?
        raise "nutkins.yaml or nutkin.yaml should contain `repository' entry for this command"
      end
      repository + '/' + img_cfg['image']
    end

    def get_all_img_names img_names
      Dir.glob("#{@project_root}/*/Dockerfile").map do |path|
        File.basename File.dirname(path)
      end
    end

    # can supply img_name or . for project root
    def get_secrets img_name
      img_dir = get_project_dir img_name
      Dir.glob("#{img_dir}/{volumes,secrets}/*.gpg")
    end

    private
    def rm_etcd_docker_container existing
      raise 'could not delete existing container' unless Docker.run 'rm', existing if existing
    end
  end
end
