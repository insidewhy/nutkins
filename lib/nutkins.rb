require "yaml"
require "ostruct"
require "net/http"
require "uri"
require "fileutils"
require "json"

require "nutkins/version"

# Must be somedomain.net instead of somedomain.net/, otherwise, it will throw exception.
module Nutkins
  CONFIG_FILE_NAME = 'nutkins.yaml'
  IMG_CONFIG_FILE_NAME = 'nutkin.yaml'
  VOLUMES_PATH = 'volumes'

  def self.download_file url, output
    orig_url = url
    tries = 10
    while (tries -= 1) >= 0
      response = Net::HTTP.get_response(URI(url))
      case response
      when Net::HTTPRedirection
        url = response["location"]
      else
        open(output, "wb") do |file|
          file.write(response.body)
        end
        return
      end
    end

    raise "could not download #{orig_url}"
  end

  def self.download_resources img_dir, resources
    resources.each do |resource|
      source = resource["source"]
      dest = File.join(img_dir, resource["dest"])
      unless File.exists? dest
        FileUtils.mkdir_p File.dirname(dest)
        print "downloading #{source}"
        Nutkins.download_file source, dest
        puts " - done"
        mode = resource["mode"]
        File.chmod(mode, dest) if mode
      end
    end
  end

  module Docker
    def self.image_id_for_tag tag
      regex = /^#{tag} +/
      `docker images`.each_line do |line|
        return line.split(' ')[2] if line =~ regex
      end
      nil
    end

    def self.container_id_for_tag tag
      regex = /^[0-9a-f]+ +#{tag} +/
      `docker ps -a`.each_line do |line|
        return line.split(' ')[0] if line =~ regex
      end
      nil
    end
  end

  module Secrets
    def get_secrets source
      dest = source.sub /\.gpg$/
      system "gpg #{source}"
      raise "could not decrypt #{archive_enc}" unless File.exists? dest
      File.chmod 0600, dest

      if dest =~ /\.tar$/
        dest_dir = File.dirname source
        system "tar xf #{archive} -C #{dest_dir}"
      end
    end
  end

  class CloudManager
    def initialize(project_dir: nil)
      @project_root = project_dir || Dir.pwd
      cfg_path = File.join(@project_root, CONFIG_FILE_NAME)
      raise "must create nutkins.yaml in project root" unless File.exists? cfg_path
      @config = OpenStruct.new(YAML.load_file cfg_path)
      @repository = @config.repository
      raise "must add `repository' entry to nutkins.yaml" if @repository.nil?
    end

    def build img_name
      cfg = get_image_config img_name
      img_dir = get_image_dir img_name
      raise "directory `#{img_dir}' does not exist" unless Dir.exists? img_dir

      build_cfg = cfg["build"]
      if build_cfg
        # download each of the files in the resources section if it doesn't exist
        resources = build_cfg["resources"]
        Nutkins.download_resources img_dir, resources if resources
      end

      tag = get_tag img_name
      prev_image_id = Docker.image_id_for_tag tag

      if system "docker", "build", "-t", tag, img_dir
        image_id = Docker.image_id_for_tag tag
        if not prev_image_id.nil? and image_id != prev_image_id
          puts "deleting previous image #{prev_image_id}"
          system "docker", "rmi", prev_image_id
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

        img_dir = get_image_dir img_name
        (create_cfg["volumes"] or []).each do |volume|
          src, dest = volume.split ' -> '
          src = File.absolute_path File.join(img_dir, VOLUMES_PATH, src)
          flags.push '-v', "#{src}:#{dest}"
        end
      end

      tag = get_tag img_name
      prev_container_id = Docker.container_id_for_tag tag unless preserve
      puts "creating new docker image"
      unless system "docker", "create", "-it", *flags, tag, *docker_args
        # TODO: delete other containers from this image
        raise "failed to create `#{img_name}' container"
      end

      unless preserve
        container_id = Docker.container_id_for_tag tag
        if not prev_container_id.nil? and container_id != prev_container_id
          puts "deleting previous container #{prev_container_id}"
          system "docker", "rm", prev_container_id
        end
      end

      puts "created `#{img_name}' container"
    end

    def run img_name, reuse: false, shell: false
      tag = get_tag img_name
      create_args = []
      if shell
        raise '--shell and --reuse arguments are incompatible' if reuse

        # TODO: test for smell-baron
        create_args = JSON.parse(`docker inspect #{tag}`)[0]["Config"]["Cmd"]
        create_args.unshift '/bin/bash', '---'
        create_args.unshift '-f' unless create_args[0] == '-f'
        # TODO: provide version that doesn't require smell-baron
      end

      id = reuse ? Docker.container_id_for_tag(tag) : nil
      if not id
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

    def rebuild_secrets paths
      puts "TODO: rebuild_secrets #{paths}"
    end

    def exec img_name, *cmd
      puts "TODO: exec #{img_name}: #{cmd.join ' '}"
    end

    private
    def get_image_config img_name
      img_cfg_path = File.join get_image_dir(img_name), IMG_CONFIG_FILE_NAME
      File.exists?(img_cfg_path) ? YAML.load_file(img_cfg_path) : {}
    end

    def get_image_dir img_name
      File.join(@project_root, img_name)
    end

    def get_tag tag
      @repository + '/' + tag
    end
  end
end
