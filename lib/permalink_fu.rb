begin
  require 'iconv'
rescue Object
  puts "no iconv, you might want to look into it."
end

require 'digest/sha1'
module PermalinkFu
  class << self
    attr_accessor :translation_to
    attr_accessor :translation_from

    # This method does the actual permalink escaping.
    def escape(string)
      result = ActiveSupport::Inflector.transliterate(string.to_s)
      result = Iconv.iconv(translation_to, translation_from, result).to_s if translation_to && translation_from
      result.gsub!(/[^\x00-\x7F]+/, '') # Remove anything non-ASCII entirely (e.g. diacritics).
      result.gsub!(/[^\w_ \-]+/i,   '') # Remove unwanted chars.
      result.gsub!(/[ \-]+/i,      '-') # No more than one of the separator in a row.
      result.gsub!(/^\-|\-$/i,      '') # Remove leading/trailing separator.
      result.downcase!
      result.size.zero? ? random_permalink(string) : result
    rescue
      random_permalink(string)
    end

    def random_permalink(seed = nil)
      rand(36**8).to_s(36)
    end
  end

  # This is the plugin method available on all ActiveRecord models.
  module PluginMethods
    # Specifies the given field(s) as a permalink, meaning it is passed through PermalinkFu.escape and set to the permalink_field.  This
    # is done
    #
    #   class Foo < ActiveRecord::Base
    #     # stores permalink form of #title to the #permalink attribute
    #     has_permalink :title
    #
    #     # stores a permalink form of "#{category}-#{title}" to the #permalink attribute
    #
    #     has_permalink [:category, :title]
    #
    #     # stores permalink form of #title to the #category_permalink attribute
    #     has_permalink [:category, :title], :category_permalink
    #
    #     # add a scope
    #     has_permalink :title, :scope => :blog_id
    #
    #     # add a scope and specify the permalink field name
    #     has_permalink :title, :slug, :scope => :blog_id
    #
    #     # do not bother checking for a unique scope
    #     has_permalink :title, :unique => false
    #
    #     # update the permalink every time the attribute(s) change
    #     # without _changed? methods (old rails version) this will rewrite the permalink every time
    #     has_permalink :title, :update => true
    #
    #   end
    #
    def has_permalink(attr_names = [], permalink_field = nil, options = {})
      include InstanceMethods

      if permalink_field.is_a?(Hash)
        options = permalink_field
        permalink_field = nil
      end


      cattr_accessor :permalink_options
      cattr_accessor :permalink_attributes
      cattr_accessor :permalink_field

      self.permalink_attributes = Array(attr_names)
      self.permalink_field      = (permalink_field || 'permalink').to_s
      self.permalink_options    = {:unique => true}.update(options)

      if self.permalink_options[:unique]
        before_validation :create_unique_permalink
      else
        before_validation :create_common_permalink
      end

      define_method :"#{self.permalink_field}=" do |value|
        write_attribute(self.permalink_field, value.blank? ? '' : PermalinkFu.escape(value))
      end

      # evaluate_attribute_method permalink_field, "def #{self.permalink_field}=(new_value);write_attribute(:#{self.permalink_field}, PermalinkFu.escape(new_value));end", "#{self.permalink_field}="
      extend  PermalinkFinders

      case options[:param]
      when false
        # nothing
      when :permalink
        include ToParam
      else
        include ToParamWithID
      end

    end
  end
  module ToParam
    def to_param
      read_attribute(self.class.permalink_field)
    end
  end

  module ToParamWithID
    def to_param
      permalink = read_attribute(self.class.permalink_field)
      return super if new_record? || permalink.blank?
      "#{id}-#{permalink}"
    end
  end

  module PermalinkFinders
    def find_by_permalink(value)
      find(:first, :conditions => { permalink_field => value  })
    end

    def find_by_permalink!(value)
      find_by_permalink(value) ||
      raise(ActiveRecord::RecordNotFound, "Couldn't find #{name} with permalink #{value.inspect}")
    end
  end

  # This contains instance methods for ActiveRecord models that have permalinks.
  module InstanceMethods
    protected
    def create_common_permalink
      return unless should_create_permalink?
      if read_attribute(self.class.permalink_field).blank? || permalink_fields_changed?
        send("#{self.class.permalink_field}=", create_permalink_for(self.class.permalink_attributes))
      end

      # Quit now if we have the changed method available and nothing has changed
      permalink_changed = "#{self.class.permalink_field}_changed?"
      return if respond_to?(permalink_changed) && !send(permalink_changed)

      # Otherwise find the limit and crop the permalink
      # andrew: if you have "limit" issues, that means you probably don't have a "permalink" column in the entries table!!
      limit   = self.class.columns_hash[self.class.permalink_field].limit
      base    = send("#{self.class.permalink_field}=", read_attribute(self.class.permalink_field)[0..limit - 1])
      [limit, base]
    end

    def create_unique_permalink
      limit, base = create_common_permalink
      return if limit.nil? # nil if the permalink has not changed or :if/:unless fail
      counter = 1
      # oh how i wish i could use a hash for conditions
      conditions = ["#{self.class.permalink_field} = ?", base]
      unless new_record?
        conditions.first << " and id != ?"
        conditions       << id
      end
      if self.class.permalink_options[:scope]
        [self.class.permalink_options[:scope]].flatten.each do |scope|
          value = send(scope)
          if value
            conditions.first << " and #{scope} = ?"
            conditions       << send(scope)
          else
            conditions.first << " and #{scope} IS NULL"
          end
        end
      end

      while ActiveRecord::Base.uncached{self.class.exists?(conditions)}
        suffix = "-#{counter += 1}"
        conditions[1] = if self.class.permalink_attributes.empty?
          PermalinkFu.random_permalink
        else
          "#{base[0..limit-suffix.size-1]}#{suffix}"
        end
        send("#{self.class.permalink_field}=", conditions[1])
      end
    end

    def create_permalink_for(attr_names)
      str = attr_names.collect { |attr_name| send(attr_name).to_s } * " "
      str.blank? ? PermalinkFu.random_permalink : str
    end

    private
    def should_create_permalink?
      if self.class.permalink_field.blank?
        false
      elsif self.class.permalink_options[:if]
        evaluate_method(self.class.permalink_options[:if])
      elsif self.class.permalink_options[:unless]
        !evaluate_method(self.class.permalink_options[:unless])
      else
        true
      end
    end

    # Don't even check _changed? methods unless :update is set
    def permalink_fields_changed?
      return false unless self.class.permalink_options[:update]
      self.class.permalink_attributes.any? do |attribute|
        changed_method = "#{attribute}_changed?"
        respond_to?(changed_method) ? send(changed_method) : true
      end
    end

    def evaluate_method(method)
      case method
      when Symbol
        send(method)
      when String
        eval(method, instance_eval { binding })
      when Proc, Method
        method.call(self)
      end
    end
  end
end

if Object.const_defined?(:Iconv)
  PermalinkFu.translation_to   = 'ascii//translit//IGNORE'
  PermalinkFu.translation_from = 'utf-8'
end

ActiveRecord::Base.extend PermalinkFu::PluginMethods
