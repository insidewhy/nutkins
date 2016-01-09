require "masterson/version"

module Masterson
  class CloudManager
    def initialize(project_dir: nil)
      @project_root = project_dir || Dir.pwd
      # TODO: scan upwards until masterson.yaml is found
      puts "TODO: initialize project at #{@project_root}"
    end

    def build image
      puts "TODO: build #{image}"
    end

    def create image
      puts "TODO: create #{image}"
    end

    def delete image
      puts "TODO: delete #{image}"
    end

    def delete_all
      puts "TODO: delete_all"
    end

    def run image
      puts "TODO: run #{image}"
    end

    def shell image
      puts "TODO: shell #{image}"
    end

    def exec image
      puts "TODO: exec #{image}"
    end
  end
end
