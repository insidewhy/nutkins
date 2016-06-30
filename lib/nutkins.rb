require "yaml"
require "ostruct"
require "net/http"
require "uri"
require "fileutils"
require "json"

module Nutkins ; end

require "nutkins/docker"
require "nutkins/download"
require "nutkins/version"

# Must be somedomain.net instead of somedomain.net/, otherwise, it will throw exception.
module Nutkins
  CONFIG_FILE_NAME = 'nutkins.yaml'
  IMG_CONFIG_FILE_NAME = 'nutkin.yaml'
  VOLUMES_PATH = 'volumes'

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
      tag = get_tag cfg

      build_cfg = cfg["build"]
      if build_cfg
        # download each of the files in the resources section if it doesn't exist
        resources = build_cfg["resources"]
        Download.download_resources img_dir, resources if resources
      end

      prev_image_id = Docker.image_id_for_tag tag

      if run_docker "build", "-t", tag, img_dir
        image_id = Docker.image_id_for_tag tag
        if not prev_image_id.nil? and image_id != prev_image_id
          puts "deleting previous image #{prev_image_id}"
          run_docker "rmi", prev_image_id
        end
      else
        raise "issue building docker image for #{img_name}"
      end
    end

    def create img_name, preserve: false, docker_args: []
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
          src = File.absolute_path File.join(img_dir, VOLUMES_PATH, src)
          flags.push '-v', "#{src}:#{dest}"
        end

        (create_cfg["env"] or {}).each do |name, val|
          flags.push '-e', "#{name}=#{val}"
        end
      end

      tag = get_tag cfg
      prev_container_id = Docker.container_id_for_tag tag unless preserve
      puts "creating new docker image"
      unless run_docker "create", "-it", *flags, tag, *docker_args
        raise "failed to create `#{img_name}' container"
      end

      unless preserve
        container_id = Docker.container_id_for_tag tag
        if not prev_container_id.nil? and container_id != prev_container_id
          puts "deleting previous container #{prev_container_id}"
          run_docker "rm", prev_container_id
        end
      end

      puts "created `#{img_name}' container"
    end

    def run img_name, reuse: false, shell: false
      cfg = get_image_config img_name
      tag = get_tag cfg
      create_args = []
      if shell
        raise '--shell and --reuse arguments are incompatible' if reuse

        # TODO: test for smell-baron
        create_args = JSON.parse(`docker inspect #{tag}`)[0]["Config"]["Cmd"]
        create_args.unshift '/bin/bash', '---'
        create_args.unshift '-f' unless create_args[0] == '-f'
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
      puts "TODO: delete #{img_name}"
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

    private
    def get_image_config path
      img_cfg_path = File.join get_project_dir(path), IMG_CONFIG_FILE_NAME
      img_cfg = File.exists?(img_cfg_path) ? YAML.load_file(img_cfg_path) : {}
      if path != '.'
        img_cfg["image"] = path
      end
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

    def run_docker *args
      system 'docker', *args
    end
  end
end
