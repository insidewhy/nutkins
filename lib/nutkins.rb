require "yaml"
require "ostruct"
require "net/http"
require "uri"
require "fileutils"

require "nutkins/version"

# Must be somedomain.net instead of somedomain.net/, otherwise, it will throw exception.
module Nutkins
  CONFIG_FILE_NAME = 'nutkins.yaml'
  IMG_CONFIG_FILE_NAME = 'nutkin.yaml'

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

      build = cfg["build"]
      if build
        resources = build["resources"]
        if resources
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
      end

      puts "TODO: build #{img_name}"
    end

    def create img_name
      puts "TODO: create #{img_name}"
    end

    def delete img_name
      puts "TODO: delete #{img_name}"
    end

    def delete_all
      puts "TODO: delete_all"
    end

    def run img_name
      puts "TODO: run #{img_name}"
    end

    def shell img_name
      puts "TODO: shell #{img_name}"
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
  end
end
