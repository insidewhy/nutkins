require_relative "docker"
require "json"
require "digest"

module Nutkins::Docker::Builder
  Docker = Nutkins::Docker

  def self.build cfg, base_tag = nil
    base = base_tag || cfg["base"]
    raise "to use build commands you must specify the base image" unless base

    # TODO: build cache from this and use to determine restore point
    # Docker.run 'inspect', tag, stderr: false
    unless Docker.run 'inspect', base, stderr: false
      puts "getting base image"
      raise "could not find base image #{base}" unless Docker.run 'pull', base, stdout: true
    end

    # the base image to start rebuilding from
    parent_img_id = Docker.get_short_commit Docker.container_id_for_name(base)
    pwd = Dir.pwd
    begin
      Dir.chdir cfg["directory"]

      cache_is_dirty = false
      build_commands = cfg["build"]["commands"]
      build_commands.each do |build_cmd|
        unless build_cmd.kind_of? Hash or build_cmd.keys.length != 1
          raise "build command should be single value hash e.g. 'run:bash'"
        end

        # build command as object, e.g. run: bash
        cmd = build_cmd.keys.first.downcase
        cmd_args = build_cmd[cmd]

        # docker run is always used and forms the basis of the cache key
        run_args = nil
        env_args = nil
        copies = []

        case cmd
        when "run"
          if cmd_args.kind_of? String
            run_args = cmd_args.gsub /\n+/, ' '
          else
            run_args = cmd_args.join ' && '
          end
        when "copy"
          if cmd_args.kind_of? String
            all_copy_args = [ cmd_args ]
          else
            all_copy_args = cmd_args
          end

          copies = all_copy_args.map do |copy_args|
            *add_files, add_files_dest = copy_args.split ' '
            add_files = add_files.map { |src| Dir.glob src }.flatten
            # ensure checksum of each file is embedded into run command
            # if any file changes the cache is dirtied

            if not run_args
              run_args = '#(nop) copy '
            else
              run_args += ';'
            end

            run_args += add_files.map do |src|
              if File.directory? src
                md5 = Digest::MD5.new
                update_md5_dir = Proc.new do |dir|
                  Dir.glob("#{dir}/*").each do |dir_entry|
                    if File.directory? dir_entry
                      update_md5_dir.call dir_entry
                    else
                      md5.update(File.read dir_entry)
                    end
                  end
                end

                update_md5_dir.call src
                hash = md5.hexdigest
              else
                hash = Digest::MD5.file(src).to_s
              end
              src + ':' + hash
            end.push(add_files_dest).join(' ')

            { srcs: add_files, dest: add_files_dest }
          end
        when "cmd", "entrypoint", "env", "expose", "label", "onbuild", "user", "volume", "workdir"
          env_args = cmd + ' ' + (cmd_args.kind_of?(String) ? cmd_args : JSON.dump(cmd_args))
          run_args = "#(nop) #{env_args}"
        else
          raise "unsupported command: #{cmd}"
          # TODO add metadata flags
        end

        if run_args
          run_shell_cmd = [ cfg['shell'], '-c', run_args ]
          unless cache_is_dirty
            # searches the commit messages of all images for the one matching the expected
            # cache entry for the given content
            cache_img_id = find_cached_img_id parent_img_id, run_shell_cmd

            if cache_img_id
              puts "cached: #{run_args}"
              parent_img_id = cache_img_id
              next
            else
              puts "not in cache: #{run_args} - starting from #{parent_img_id}"
              cache_is_dirty = true
            end
          end

          if run_args
            puts "run #{run_args}"
            unless Docker.run 'run', parent_img_id, *run_shell_cmd, stdout: true
              raise "run failed: #{run_args}"
            end

            cont_id = `docker ps -aq`.lines.first.strip
            begin
              unless copies.empty?
                copies.each do |copy|
                  copy[:srcs].each do |src|
                    if not Docker.run 'cp', src, "#{cont_id}:#{copy[:dest]}"
                      raise "could not copy #{src} to #{cont_id}:#{copy[:dest]}"
                    end
                  end
                end
              end

              commit_args = env_args ? ['-c', env_args] : []
              parent_img_id = Docker.run_get_stdout 'commit', *commit_args, cont_id
              raise "could not commit docker image" if parent_img_id.nil?
              parent_img_id = Docker.get_short_commit parent_img_id
            ensure
              if not Docker.run 'rm', cont_id
                puts "could not remove build container #{cont_id}"
              end
            end
          end
        else
          puts "TODO: support cmd #{build_cmd}"
        end
      end
    ensure
      Dir.chdir pwd
    end

    Docker.run 'tag', parent_img_id, cfg['tag']
  end

  def self.find_cached_img_id parent_img_id, command
    all_images = Docker.run_get_stdout('images', '-aq').split("\n")
    images_meta = JSON.parse(Docker.run_get_stdout('inspect', *all_images))
    images_meta.each do |image_meta|
      if image_meta.dig('ContainerConfig', 'Cmd') == command and
         Docker.get_short_commit(image_meta['Parent']) == parent_img_id
        return Docker.get_short_commit(image_meta['Id'])
      end
    end
    nil
  end
end
