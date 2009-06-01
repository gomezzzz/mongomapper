module MongoMapper  
  module Document
    def self.included(model)
      model.extend ClassMethods
      model.class_eval do
        include Validatable
        include Validation
        include ActiveSupport::Callbacks
        
        define_callbacks  :before_validation_on_create, :before_validation_on_update,
                          :before_validation,           :after_validation,
                          :before_create,               :after_create, 
                          :before_update,               :after_update,
                          :before_save,                 :after_save,
                          :before_destroy,              :after_destroy
        
        key :_id, String
        key :created_at, Time
        key :updated_at, Time
      end
    end
    
    module ClassMethods
      def find(*args)
        options = args.extract_options!
        
        case args.first
          when :first then find_first(options)
          when :last  then find_last(options)
          when :all   then find_every(options)
          else             find_from_ids(args)
        end
      end
      
      def find_by_id(id)
        doc = collection.find_first({:_id => id})
        doc ? new(doc) : nil
      end
      
      def count(conditions={})
        collection.count(conditions)
      end
      
      def create(*docs)
        rows = []
        docs.flatten.each { |attrs| rows << new(attrs).save }
        rows.size == 1 ? rows[0] : rows
      end
      
      # For updating single document
      #   Person.update(1, {:foo => 'bar'})
      #
      # For updating multiple documents at once:
      #   Person.update({'1' => {:foo => 'bar'}, '2' => {:baz => 'wick'}}) 
      def update(*args)
        updating_multiple = args.length == 1
        
        if updating_multiple
          update_multiple(args[0])
        else
          update_single(args[0], args[1])
        end
      end
      
      def delete(*ids)
        ids.flatten.each { |id| collection.remove(:_id => id) }
      end
      
      def delete_all(conditions={})
        collection.remove(conditions)
      end
      
      def destroy(*ids)
        ids.flatten.each { |id| find(id).destroy }
      end
      
      def destroy_all(conditions={})
        find(:all, :conditions => conditions).map(&:destroy)
      end
      
      def connection(mongo_connection=nil)
        if mongo_connection.nil?
          @connection ||= MongoMapper.connection
        else
          @connection = mongo_connection
        end
        
        @connection
      end
      
      def database(name=nil)
        if name.nil?
          @database ||= MongoMapper.database
        else
          @database = connection.db(name)
        end
        
        @database
      end
      
      def collection(name=nil)
        if name.nil?
          @collection ||= database.collection(self.class.to_s.tableize)
        else
          @collection = database.collection(name)
        end
        
        @collection
      end
      
      def key(name, type, options={})
        key = Key.new(name, type, options)
        keys[key.name] = key
        apply_validations_for(key)
        define_subdocument_accessors_for(key)
        create_indexes_for(key)
        key
      end
      
      def keys
        @keys ||= HashWithIndifferentAccess.new
      end
      
      # TODO: remove to_s when ruby driver supports symbols (I sent patch)
      def ensure_index(name_or_array, options={})
        keys_to_index = if name_or_array.is_a?(Array)
          name_or_array.map { |pair| [pair[0].to_s, pair[1]] }
        else
          name_or_array.to_s
        end
        collection.create_index(keys_to_index, options.delete(:unique))
      end
      
      private        
        def find_every(options)
          criteria, options = FinderOptions.new(options).to_a
          collection.find(criteria, options).to_a.map { |doc| new(doc) }
        end

        def find_first(options)
          find_every(options.merge(:limit => 1, :order => 'created_at')).first
        end

        def find_last(options)
          find_every(options.merge(:limit => 1, :order => 'created_at desc')).first
        end

        def find_some(ids)
          documents = find_every(:conditions => {'_id' => ids})
          if ids.size == documents.size
            documents
          else
            raise DocumentNotFound, "Couldn't find all of the ids (#{ids.to_sentence}). Found #{documents.size}, but was expecting #{ids.size}"
          end
        end

        def find_from_ids(*ids)
          ids = ids.flatten.compact.uniq

          case ids.size
            when 0
              raise(DocumentNotFound, "Couldn't find without an ID")
            when 1
              find_by_id(ids[0]) || raise(DocumentNotFound, "Document with id of #{ids[0]} does not exist in collection named #{collection.name}")
            else
              find_some(ids)
          end
        end
        
        def update_single(id, attrs)
          if id.blank? || attrs.blank? || !attrs.is_a?(Hash)
            raise ArgumentError, "Updating a single document requires an id and a hash of attributes"
          end
          doc = find(id)
          doc.update_attributes(attrs)
        end
        
        def update_multiple(docs)
          unless docs.is_a?(Hash)
            raise ArgumentError, "Updating multiple documents takes 1 argument and it must be hash"
          end
          docs.inject([]) do |rows, doc|
            rows << update(doc[0], doc[1])
            rows
          end
        end
        
        def define_subdocument_accessors_for(key)
          return unless key.subdocument?
          instance_var = "@#{key.name}"
          
          define_method(key.name) do
            key.get(instance_variable_get(instance_var))
          end
          
          define_method("#{key.name}=") do |value|
            instance_variable_set(instance_var, key.get(value))
          end
        end
        
        def create_indexes_for(key)
          ensure_index key.name if key.options[:index]
        end
    end
    
    ####################
    # Instance Methods #
    ####################
    
    def initialize(attrs={})
      self.attributes = attrs
    end
    
    def collection
      self.class.collection
    end
    
    def new?
      read_attribute('_id').blank? || self.class.find_by_id(id).blank?
    end
        
    def save
      run_callbacks(:before_save)
      new? ? create : update
      run_callbacks(:after_save)
      self
    end
    
    def update_attributes(attrs={})
      self.attributes = attrs
      save
    end
    
    def destroy
      run_callbacks(:before_destroy)
      collection.remove(:_id => id) unless new?
      run_callbacks(:after_destroy)
      freeze
    end
    
    def attributes=(attrs)
      attrs.each_pair do |key_name, value|
        write_attribute(key_name, value) if writer?(key_name)
      end
    end
    
    def attributes
      self.class.keys.inject(HashWithIndifferentAccess.new) do |hash, key_hash|
        name, key = key_hash
        value = if key.native?
          read_attribute(name)
        else
          subdocument = read_attribute(name)
          subdocument && subdocument.attributes
        end
        hash[name] = value unless value.nil?
        hash
      end
    end
    
    def reader?(name)
      defined_key_names.include?(name.to_s)
    end
    
    def writer?(name)
      name = name.to_s
      name = name.chop if name.ends_with?('=')
      reader?(name)
    end
    
    def before_typecast_reader?(name)
      name.to_s.match(/^(.*)_before_typecast$/) && reader?($1)
    end
    
    def [](name)
      read_attribute(name)
    end
    
    def []=(name, value)
      write_attribute(name, value)
    end
    
    def id
      read_attribute('_id')
    end
    
    def method_missing(method, *args, &block)
      attribute = method.to_s
      
      if reader?(attribute)
        read_attribute(attribute)
      elsif writer?(attribute)
        write_attribute(attribute.chop, args[0])
      elsif before_typecast_reader?(attribute)
        read_attribute_before_typecast(attribute.gsub(/_before_typecast$/, ''))
      else
        super
      end
    end
    
    def ==(other)
      id == other.id && self.class == other.class
    end
    
    def inspect
      attributes_as_nice_string = defined_key_names.collect do |name|
        "#{name}: #{read_attribute(name)}"
      end.join(", ")
      "#<#{self.class} #{attributes_as_nice_string}>"
    end
    
    def respond_to?(method, include_private=false)
      return true if reader?(method) || writer?(method) || before_typecast_reader?(method)
      super(method, include_private)
    end
    
    private
      def create
        write_attribute('_id', generate_id) if read_attribute('_id').blank?
        update_timestamps
        run_callbacks(:before_create)        
        collection.insert(attributes)
        run_callbacks(:after_create)
      end
      
      def update
        update_timestamps
        run_callbacks(:before_update)
        collection.modify({:_id => id}, attributes)
        run_callbacks(:after_update)
      end
      
      def update_timestamps
        write_attribute('created_at', Time.now.utc) if new? && writer?(:created_at)
        write_attribute('updated_at', Time.now.utc) if writer?(:updated_at)
      end
      
      def generate_id
        XGen::Mongo::Driver::ObjectID.new
      end
      
      def read_attribute(name)
        defined_key(name).get(instance_variable_get("@#{name}"))
      end
      
      def read_attribute_before_typecast(name)
        instance_variable_get("@#{name}_before_typecast")
      end
      
      def write_attribute(name, value)
        instance_variable_set "@#{name}_before_typecast", value
        instance_variable_set "@#{name}", defined_key(name).set(value)
      end
    
      def defined_key(name)
        self.class.keys[name]
      end
      
      def defined_key_names
        self.class.keys.keys
      end
      
      def only_defined_keys(hash={})
        defined_key_names = defined_key_names()
        hash.delete_if { |k, v| !defined_key_names.include?(k.to_s) }
      end
  end # Document
end # MongoMapper