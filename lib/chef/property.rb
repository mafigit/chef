require 'chef/exceptions'
require 'chef/delayed_evaluator'

class Chef
  #
  # Type and validation information for a property on a resource.
  #
  # A property named "x" manipulates the "@x" instance variable on a
  # resource.  The *presence* of the variable (`instance_variable_defined?(@x)`)
  # tells whether the variable is defined; it may have any actual value,
  # constrained only by validation.
  #
  # Properties may have validation, defaults, and coercion, and have full
  # support for lazy values.
  #
  # @see Chef::Resource.property
  # @see Chef::DelayedEvaluator
  #
  class Property
    #
    # Create a new property.
    #
    # @param options [Hash<Symbol,Object>] Property options, including
    #   control options here, as well as validation options (see
    #   Chef::Mixin::ParamsValidate#validate for a description of validation
    #   options).
    #   @option options [Symbol] :name The name of this property.
    #   @option options [Class] :declared_in The class this property comes from.
    #   @option options [Symbol] :instance_variable_name The instance variable
    #     tied to this property. Must include a leading `@`. Defaults to `@<name>`.
    #     `nil` means the property is opaque and not tied to a specific instance
    #     variable.
    #   @option options [Boolean] :desired_state `true` if this property is part of desired
    #     state. Defaults to `true`. If `identity` is true, `desired_state` will
    #     also be true.
    #   @option options [Boolean] :identity `true` if this property is part of object
    #     identity. Defaults to `false`.
    #   @option options [Boolean] :name_property `true` if this
    #     property defaults to the same value as `name`. Equivalent to
    #     `default: lazy { name }`, except that #property_is_set? will
    #     return `true` if the property is set *or* if `name` is set.
    #   @option options [Object] :default The value this property
    #     will return if the user does not set one. If this is `lazy`, it will
    #     be run in the context of the instance (and able to access other
    #     properties).
    #   @option options [Proc] :coerce A proc which will be called to
    #     transform the user input to canonical form. The value is passed in,
    #     and the transformed value returned as output. Lazy values will *not*
    #     be passed to this method until after they are evaluated. Called in the
    #     context of the resource (meaning you can access other properties).
    #   @option options [Boolean] :required `true` if this property
    #     must be present; `false` otherwise. This is checked after the resource
    #     is fully initialized.
    #
    def initialize(**options)
      options.each { |k,v| options[k.to_sym] = v if k.is_a?(String) }
      options[:name_property] = options.delete(:name_attribute) unless options.has_key?(:name_property)
      @options = options

      options[:name] = options[:name].to_sym if options[:name]
      options[:instance_variable_name] = options[:instance_variable_name].to_sym if options[:instance_variable_name]
    end

    #
    # The name of this property.
    #
    # @return [String]
    #
    def name
      options[:name]
    end

    #
    # The class this property was defined in.
    #
    # @return [Class]
    #
    def declared_in
      options[:declared_in]
    end

    #
    # The instance variable associated with this property.
    #
    # Defaults to `@<name>`
    #
    # @return [Symbol]
    #
    def instance_variable_name
      if options.has_key?(:instance_variable_name)
        options[:instance_variable_name]
      elsif name
        :"@#{name}"
      end
    end

    #
    # Whether this is part of the resource's natural identity or not.
    #
    # @return [Boolean]
    #
    def identity?
      options[:identity]
    end

    #
    # Whether this is part of desired state or not.
    #
    # Defaults to true.
    #
    # identity implies desired state: if identity? is true, desired_state? will
    # be true as well.
    #
    # @return [Boolean]
    #
    def desired_state?
      return true if !options.has_key?(:desired_state)
      options[:desired_state] || identity?
    end

    #
    # Whether this is name_property or not.
    #
    # @return [Boolean]
    #
    def name_property?
      options[:name_property]
    end

    #
    # Whether this property has a default value.
    #
    # @return [Boolean]
    #
    def has_default?
      options.has_key?(:default)
    end

    #
    # Whether this property is required or not.
    #
    # @return [Boolean]
    #
    def required?
      options[:required]
    end

    #
    # Validation options.  (See Chef::Mixin::ParamsValidate#validate.)
    #
    # @return [Hash<Symbol,Object>]
    #
    def validation_options
      @validation_options ||= options.reject { |k,v|
        [:declared_in,:name,:desired_state,:identity,:instance_variable_name,:default,:name_property,:coerce,:required].include?(k) }
    end

    #
    # Handle the property being called.
    #
    # The base implementation does the property get-or-set:
    #
    # ```ruby
    # resource.myprop # get
    # resource.myprop value # set
    # ```
    #
    # If multiple values or a block are passed, they will be passed to coerce.
    # If there is no coerce method and multiple values are passed, we will throw
    # an error.
    #
    # @param resource [Chef::Resource] The resource to get the property from.
    # @param value The value to set the property to. If not passed or set to
    #   NOT_PASSED, this is treated as a get.
    #
    # @return The current value of the property. If it is a `set`, lazy values
    #   will be returned without running, validating or coercing. If it is a
    #   `get`, the non-lazy, coerced, validated value will always be returned.
    #
    def call(resource, value=NOT_PASSED)
      # myprop with no args
      if value == NOT_PASSED
        return get(resource)
      end

      # myprop nil is sometimes a get (backcompat)
      if value.nil? && !explicitly_accepts_nil?(resource)
        # If you say "my_property nil" and the property explicitly accepts
        # nil values, we consider this a get.
        # Chef::Log.deprecation("#{name} nil currently does not overwrite the value of #{name}. This will change in Chef 13, and the value will be set to nil instead. Please change your code to explicitly accept nil using \"property :#{name}, [MyType, nil]\", or stop setting this value to nil.")
        return get(resource)
      end

      # Anything else (myprop value) is a set
      set(resource, value)
    end

    #
    # Get the property value from the resource, handling lazy values,
    # defaults, and validation.
    #
    # - If the property's value is lazy, the lazy value is evaluated, coerced
    #   and validated, and the result stored in the property (it will not be
    #   evaluated twice).
    # - If the property has no value, and is required, raises ValidationFailed.
    # - If the property has no value, but has a default, the default value
    #   will be returned. If the default value is lazy, it will be evaluated,
    #   coerced and validated, and the result stored in the property.
    # - If the property has no value, but is name_property, `resource.name`
    #   is retrieved, coerced, validated and stored in the property.
    # - Otherwise, `nil` is returned.
    #
    # @param resource [Chef::Resource] The resource to get the property from.
    #
    # @return The value of the property.
    #
    # @raise Chef::Exceptions::ValidationFailed If the value is invalid for
    #   this property, or if the value is required and not set.
    #
    def get(resource)
      if is_set?(resource)
        value = get_value(resource)
        if value.is_a?(DelayedEvaluator)
          value = exec_in_resource(resource, value)
          value = coerce(resource, value)
        end
        value

      else
        raise Chef::Exceptions::ValidationFailed, "#{name} is required" if required?
        set(resource, default(resource)) if has_default? || name_property?

      end
    end

    #
    # Set the value of this property in the given resource.
    #
    # Non-lazy values are coerced and validated before being set. Coercion
    # and validation of lazy values is delayed until they are first retrieved.
    #
    # @param resource [Chef::Resource] The resource to set this property in.
    # @param value The value to set.
    #
    # @return The value that was set, after coercion (if lazy, still returns
    #   the lazy value)
    #
    # @raise Chef::Exceptions::ValidationFailed If the value is invalid for
    #   this property.
    #
    def set(resource, value)
      value = coerce(resource, value) unless value.is_a?(DelayedEvaluator)
      set_value(resource, value)
    end

    #
    # Get the default value for this property.
    #
    # - If the property has a default, the default value will be returned. If
    #   the default value is lazy, it will be evaluated, coerced, validated and
    #   returned.
    # - If the property is a name_property, `resource.name` is coerced,
    #   validated and returned.
    # - Otherwise, `nil` is returned.
    #
    # This differs from `get` in that it will *not* store the default value in
    # the given resource.
    #
    # If resource and name are not passed, the default is returned without
    # evaluation, coercion or validation, and name_property is not honored.
    #
    # @param resource [Chef::Resource] The resource to get the default against.
    #
    # @return The default value for the property.
    #
    # @raise Chef::Exceptions::ValidationFailed If the value is invalid for
    #   this property.
    #
    def default(resource=nil)
      return delazify(resource, options[:default]) if options.has_key?(:default)
      return coerce(resource, resource.name) if name_property? && resource && name != :name
      nil
    end

    #
    # Find out whether this property has been set.
    #
    # This will be true if:
    # - The user explicitly set the value
    # - The property has a default, and the value was retrieved.
    #
    # From this point of view, it is worth looking at this as "what does the
    # user think this value should be." In order words, if the user grabbed
    # the value, even if it was a default, they probably based calculations on
    # it. If they based calculations on it and the value changes, the rest of
    # the world gets inconsistent.
    #
    # @param resource [Chef::Resource] The resource to get the property from.
    #
    # @return [Boolean]
    #
    def is_set?(resource)
      value_is_set?(resource)
    end

    #
    # Coerce an input value into canonical form for the property, validating
    # it in the process.
    #
    # After coercion, the value is suitable for storage in the resource.
    #
    # Does no special handling for lazy values.
    #
    # @param resource [Chef::Resource] The resource we're coercing against
    #   (to provide context for the coerce).
    # @param value The value to coerce.
    #
    # @return The coerced value.
    #
    # @raise Chef::Exceptions::ValidationFailed If the value is invalid for
    #   this property.
    #
    def coerce(resource, value)
      value = exec_in_resource(resource, options[:coerce], value) if options.has_key?(:coerce)
      validate(resource, value)
      value
    end

    #
    # Validate a value.
    #
    # Calls Chef::Mixin::ParamsValidate#validate with #validation_options as
    # options.
    #
    # @param resource [Chef::Resource] The resource we're validating against
    #   (to provide context for the validate).
    # @param value The value to validate.
    #
    # @raise Chef::Exceptions::ValidationFailed If the value is invalid for
    #   this property.
    #
    def validate(resource, value)
      resource.validate({ name => value }, { name => validation_options })
    end

    #
    # Specialize this Property by making a duplicate with some added or
    # changed options.
    #
    # @param options [Hash<Symbol,Object>] List of options that would be passed
    #   to #initialize.
    #
    # @return [Property] The new property type.
    #
    def specialize(**modified_options)
      Property.new(**options, **modified_options)
    end

    protected

    #
    # Find out whether this type accepts nil explicitly.
    #
    # A type accepts nil explicitly if it validates as nil, *and* is not simply
    # an empty type.
    #
    # These examples accept nil explicitly:
    # ```ruby
    # property :a, [ String, nil ]
    # property :a, is: [ String, nil ]
    # property :a, equal_to: [ 1, 2, 3, nil ]
    # property :a, kind_of: [ String, NilClass ]
    # property :a, respond_to: [ ]
    # ```
    #
    # These do not:
    # ```ruby
    # property :a, [ String, nil ], cannot_be: :nil
    # property :a, callbacks: { x: }
    # ```
    #
    # This does not either (accepts nil implicitly only):
    # ```ruby
    # property :a
    # ```
    #
    # @param resource [Chef::Resource] The resource we're coercing against
    #   (to provide context for the coerce).
    #
    # @return [Boolean] Whether this value explicitly accepts nil.
    #
    # @api private
    def explicitly_accepts_nil?(resource)
      options.has_key?(:is) && resource.send(:_pv_is, { name => nil }, name, options[:is], raise_error: false)
    end

    def get_value(resource)
      if instance_variable_name
        resource.send(:instance_variable_get, instance_variable_name)
      else
        resource.send(name)
      end
    end

    def set_value(resource, value)
      if instance_variable_name
        resource.send(:instance_variable_set, instance_variable_name, value)
      else
        resource.send(name, value)
      end
    end

    def value_is_set?(resource)
      if instance_variable_name
        resource.send(:instance_variable_defined?, instance_variable_name)
      else
        true
      end
    end

    def delazify(resource, value, *args)
      return value if !value.is_a?(DelayedEvaluator)
      exec_in_resource(resource, value, *args)
    end

    def exec_in_resource(resource, proc, *args)
      if resource
        if proc.arity > args.size
          value = proc.call(resource, *args)
        else
          value = resource.instance_exec(*args, &proc)
        end
      else
        value = proc.call
      end

      if value.is_a?(DelayedEvaluator)
        value = coerce(resource, value)
      end
      value
    end

    attr_reader :options
  end
end
