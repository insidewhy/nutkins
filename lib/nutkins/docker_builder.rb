require_relative "docker"
require "json"
require "digest"

module Nutkins::DockerBuilder
  def self.build cfg
    base = cfg["base"]
    raise "to use build commands you must specify the base image" unless base

    # TODO: build cache from this and use to determine restore point
    # Nutkins::Docker.run 'inspect', tag, stderr: false

    unless Nutkins::Docker.run 'inspect', base, stderr: false
      puts "getting base image"
      Docker.run 'pull', base, stdout: true
    end

    cont_id = Nutkins::Docker.container_id_for_tag base, running: true
    if cont_id
      puts "found existing container #{cont_id}"
      Nutkins::Docker.kill_and_remove_container cont_id
      puts "killed and removed existing container"
    end

    # the base image to start rebuilding from
    cache_base = base
    cont_id = nil
    pwd = Dir.pwd
    begin
      Dir.chdir cfg["directory"]

      cache_is_dirty = false
      build_commands = cfg["build"]["commands"]
      build_commands.each do |build_cmd|
        cmd = /^\w+/.match(build_cmd).to_s.downcase
        cmd_args = build_cmd[(cmd.length + 1)..-1].strip

        docker_args = []
        # the commit_msg is used to look up cache entries, it can be
        # modified if the command uses dynamic data, e.g. to add checksums
        commit_msg = nil

        case cmd
        when "run"
          cmd_args.gsub! /\n+/, ' '
          docker_args = ['exec', '%CONT_ID%', cfg['shell'], '-c', cmd_args]
          commit_msg = cmd + ' ' + cmd_args
        when "add"
          *srcs, dest = cmd_args.split ' '
          srcs = srcs.map { |src| Dir.glob src }.flatten

          docker_args = srcs.map { |src| ['cp', src, '%CONT_ID%' + ':' + dest] }
          # ensure checksum of each file is embedded into commit_msg
          # if any file changes the cache is dirtied
          commit_msg = 'add ' + srcs.map do |src|
            src + ':' + Digest::MD5.file(src).to_s
          end.push(dest).join(' ')
        else
          # TODO add metadata flags
        end

        if docker_args and commit_msg
          unless cache_is_dirty
            # searches the commit messages of all images for the one matching the expected
            # cache entry for the given content
            all_images = Nutkins::Docker.run_get_stdout('images', '-aq').split("\n")
            images_meta = JSON.parse(Nutkins::Docker.run_get_stdout('inspect', *all_images))
            cache_entry = images_meta.find do |image_meta|
              if image_meta['Comment'] == commit_msg
                cache_base = image_meta['Id'].sub(/^sha256:/, '')[0...12]
                true
              end
            end

            if cache_entry
              puts "cached: #{commit_msg}"
              next
            else
              puts "starting build container from commit #{cache_base}"
              Nutkins::Docker.run 'run', '-d', cache_base, 'sleep', '3600'
              cont_id = Nutkins::Docker.container_id_for_tag cache_base, running: true
              puts "started build container #{cont_id}"
              cache_is_dirty = true
            end
          end

          puts "#{cmd}: #{cmd_args}"

          # docker can be an array of one set of args, or an array of arrays of args
          docker_args = [ docker_args ] unless docker_args[0].kind_of? Array
          docker_args.each do |one_docker_args|
            run_args = one_docker_args.map { |arg| arg.gsub '%CONT_ID%', cont_id }
            puts "run #{run_args.join ' '}"
            unless Nutkins::Docker.run *run_args, stdout: true
              raise "build failed: #{one_docker_args.join ' '}"
            end
          end
          Nutkins::Docker.run 'commit', '-m', commit_msg, cont_id
        else
          puts "TODO: support cmd #{build_cmd}"
        end
      end
    ensure
      Dir.chdir pwd
      Nutkins::Docker.kill_and_remove_container cont_id if cont_id
      puts "killed and removed build container"
    end
  end
end
