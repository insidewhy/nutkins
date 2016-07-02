require 'open3'

module Nutkins::Docker
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

  def self.container_id_for_name name
    stdout, stderr, status = Open3.capture3 'docker', 'inspect', '--format="{{.Id}}"', name
    status.success? && stdout.chomp
  end

  def self.run *args
    system 'docker', *args
  end
end
