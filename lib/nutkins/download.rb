require 'uri'
require 'zlib'
require 'rubygems/package'

module Nutkins::Download
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
        extract = resource["extract"]
        if extract
          uri = URI.parse(source)
          Dir.mktmpdir do |tmpdir|
            dl_dest = File.join tmpdir, File.basename(uri.path)
            print "downloading #{source} to #{dl_dest}"
            download_file source, dl_dest
            puts " - done"
            File.open(dl_dest, "rb") do |file|
              Zlib::GzipReader.wrap(file) do |gz|
                Gem::Package::TarReader.new(gz) do |tar|
                  matching = tar.detect { |entry| File.fnmatch(extract, entry.full_name) }
                  raise "could not find file matching #{extract} in #{dl_dest}" unless matching
                  FileUtils.mkdir_p File.dirname(dest)
                  File.write(dest, matching.read)
                end
              end
            end
          end
        else
          FileUtils.mkdir_p File.dirname(dest)
          print "downloading #{source} to #{dest}"
          download_file source, dest
          puts " - done"
        end

        mode = resource["mode"]
        File.chmod(mode, dest) if mode
      end
    end
  end
end
