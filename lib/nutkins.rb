require "nutkins/version"

module Nutkins
  class CloudManager
    def initialize(project_dir: nil)
      @project_root = project_dir || Dir.pwd
      # TODO: scan upwards until nutkins.yaml is found
      puts "TODO: initialize project at #{@project_root}"
    end

    def build paths
      puts "TODO: build #{paths}"
    end

    def create paths
      puts "TODO: create #{paths}"
    end

    def delete paths
      puts "TODO: delete #{paths}"
    end

    def delete_all
      puts "TODO: delete_all"
    end

    def run path
      puts "TODO: run #{path}"
    end

    def shell path
      puts "TODO: shell #{path}"
    end

    def exec path, *cmd
      puts "TODO: exec #{path}: #{cmd.join ' '}"
    end
  end
end
