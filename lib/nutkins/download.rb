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
        FileUtils.mkdir_p File.dirname(dest)
        print "downloading #{source}"
        download_file source, dest
        puts " - done"
        mode = resource["mode"]
        File.chmod(mode, dest) if mode
      end
    end
  end
end
