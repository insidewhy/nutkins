unless Hash.new.respond_to? :dig
  class Hash
    def dig first_key, *other_keys
      val = self[first_key]
      if other_keys.empty?
        val
      elsif val and val.kind_of? Hash
        val.dig *other_keys
      else
        nil
      end
    end
  end
end
