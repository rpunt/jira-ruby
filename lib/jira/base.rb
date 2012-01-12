require 'active_support/core_ext/string'
require 'active_support/inflector'

module JIRA

  class Base

    attr_reader :client
    attr_accessor :expanded, :deleted, :attrs
    alias :expanded? :expanded
    alias :deleted? :deleted

    def initialize(client, options = {})
      @client   = client
      @attrs    = options[:attrs] || {}
      @expanded = options[:expanded] || false
      @deleted  = false

      # If this class has any belongs_to relationships, a value for
      # each of them must be passed in to the initializer.
      self.class.belongs_to_relationships.each do |relation|
        if options[relation]
          instance_variable_set("@#{relation.to_s}", options[relation])
          instance_variable_set("@#{relation.to_s}_id", options[relation].key_value)
        elsif options["#{relation}_id".to_sym]
          instance_variable_set("@#{relation.to_s}_id", options["#{relation}_id".to_sym])
        else
          raise ArgumentError.new("Required option #{relation.inspect} missing") unless options[relation]
        end
      end
    end

    # The class methods are never called directly, they are always
    # invoked from a BaseFactory subclass instance.
    def self.all(client, options = {})
      response = client.get(rest_base_path(client))
      json = parse_json(response.body)
      puts collection_attributes_are_nested
      if collection_attributes_are_nested
        json = json[endpoint_name.pluralize]
      end
      json.map do |attrs|
        self.new(client, {:attrs => attrs}.merge(options))
      end
    end

    def self.find(client, key, options = {})
      instance = self.new(client, options)
      instance.attrs[key_attribute.to_s] = key
      instance.fetch
      instance
    end

    def self.build(client, attrs)
      self.new(client, :attrs => attrs)
    end

    def self.rest_base_path(client, prefix = '/')
      client.options[:rest_base_path] + prefix + self.endpoint_name
    end

    def self.endpoint_name
      self.name.split('::').last.downcase
    end

    def self.collection_path(client, prefix = '/')
      rest_base_path(client, prefix)
    end

    def self.singular_path(client, key, prefix = '/')
      rest_base_path(client, prefix) + '/' + key
    end

    def self.key_attribute
      :id
    end

    def self.parse_json(string)
      JSON.parse(string)
    end

    def self.has_one(resource, options = {})
      attribute_key = options[:attribute_key] || resource.to_s
      child_class = options[:class] || ('JIRA::Resource::' + resource.to_s.classify).constantize
      define_method(resource) do
        attribute = maybe_nested_attribute(attribute_key, options[:nested_under])
        return nil unless attribute
        child_class.new(client, :attrs => attribute)
      end
    end

    def self.has_many(collection, options = {})
      attribute_key = options[:attribute_key] || collection.to_s
      child_class = options[:class] || ('JIRA::Resource::' + collection.to_s.classify).constantize
      self_class_basename = self.name.split('::').last.downcase.to_sym
      define_method(collection) do
        child_class_options = {self_class_basename => self}
        attribute = maybe_nested_attribute(attribute_key, options[:nested_under]) || []
        collection = attribute.map do |child_attributes|
          child_class.new(client, child_class_options.merge(:attrs => child_attributes))
        end
        HasManyProxy.new(self, child_class, collection)
      end
    end

    def self.belongs_to_relationships
      @belongs_to_relationships ||= []
    end

    def self.belongs_to(resource)
      belongs_to_relationships.push(resource)
      attr_reader resource
      attr_reader "#{resource}_id"
    end

    def self.collection_attributes_are_nested
      @collection_attributes_are_nested ||= false
    end

    def self.nested_collections(value)
      @collection_attributes_are_nested = value
    end

    # Returns a symbol for the given instance, for example
    # JIRA::Resource::Issue returns :issue
    def to_sym
      self.class.endpoint_name.to_sym
    end

    def respond_to?(method_name)
      if attrs.keys.include? method_name.to_s
        true
      else
        super(method_name)
      end
    end

    def method_missing(method_name, *args, &block)
      if attrs.keys.include? method_name.to_s
        attrs[method_name.to_s]
      else
        super(method_name)
      end
    end

    # Each resource has a unique key attribute, this method returns the value
    # of that key for this instance.
    def key_value
      @attrs[self.class.key_attribute.to_s]
    end

    def rest_base_path(prefix = "/")
      # Just proxy this to the class method
      self.class.rest_base_path(client, prefix)
    end

    # This returns the URL path component that is specific to this instance,
    # for example for Issue id 123 it returns '/issue/123'.  For an unsaved
    # issue it returns '/issue'
    def path_component
      path_component = "/#{self.class.endpoint_name}"
      if key_value
        path_component += '/' + key_value
      end
      path_component
    end

    def fetch(reload = false)
      return if expanded? && !reload
      response = client.get(url)
      set_attrs_from_response(response)
      @expanded = true
    end

    def save!(attrs)
      http_method = new_record? ? :post : :put
      response = client.send(http_method, url, attrs.to_json)
      set_attrs(attrs, false)
      set_attrs_from_response(response)
      @expanded = false
      true
    end

    def save(attrs)
      begin
        save_status = save!(attrs)
      rescue JIRA::HTTPError => exception
        set_attrs_from_response(exception.response) rescue JSON::ParserError  # Merge error status generated by JIRA REST API
        save_status = false
      end
      save_status
    end

    def set_attrs_from_response(response)
      unless response.body.nil? or response.body.length < 2
        json = self.class.parse_json(response.body)
        set_attrs(json)
      end
    end

    # Set the current attributes from a hash.  If clobber is true, any existing
    # hash values will be clobbered by the new hash, otherwise the hash will
    # be deeply merged into attrs.  The target paramater is for internal use only
    # and should not be used.
    def set_attrs(hash, clobber=true, target = nil)
      target ||= @attrs
      if clobber
        target.merge!(hash)
        hash
      else
        hash.each do |k, v|
          if v.is_a?(Hash)
            set_attrs(v, clobber, target[k])
          else
            target[k] = v
          end
        end
      end
    end

    def delete
      client.delete(url)
      @deleted = true
    end

    def has_errors?
      respond_to?('errors')
    end

    def url
      prefix = '/'
      unless self.class.belongs_to_relationships.empty?
        prefix = self.class.belongs_to_relationships.inject(prefix) do |prefix_so_far, relationship|
          prefix_so_far + relationship.to_s + "/" + self.send("#{relationship.to_s}_id") + '/'
        end
      end
      if @attrs['self']
        @attrs['self']
      elsif key_value
        self.class.singular_path(client, key_value.to_s, prefix)
      else
        self.class.collection_path(client, prefix)
      end
    end

    def to_s
      "#<#{self.class.name}:#{object_id} @attrs=#{@attrs.inspect}>"
    end

    def to_json
      attrs.to_json
    end

    def new_record?
      key_value.nil?
    end

    protected

    # This allows conditional lookup of possibly nested attributes.  Example usage:
    #
    #   maybe_nested_attribute('foo')                 # => @attrs['foo']
    #   maybe_nested_attribute('foo', 'bar')          # => @attrs['bar']['foo']
    #   maybe_nested_attribute('foo', ['bar', 'baz']) # => @attrs['bar']['baz']['foo']
    #
    def maybe_nested_attribute(attribute_name, nested_under = nil)
      self.class.maybe_nested_attribute(@attrs, attribute_name, nested_under)
    end

    def self.maybe_nested_attribute(attributes, attribute_name, nested_under = nil)
      return attributes[attribute_name] if nested_under.nil?
      if nested_under.instance_of? Array
        final = nested_under.inject(attributes) do |parent, key|
          break if parent.nil?
          parent[key]
        end
        return nil if final.nil?
        final[attribute_name]
      else
        return attributes[nested_under][attribute_name]
      end
    end

  end
end