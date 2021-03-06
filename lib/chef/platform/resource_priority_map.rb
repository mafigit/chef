require 'singleton'

class Chef
  class Platform
    class ResourcePriorityMap
      include Singleton

      def get_priority_array(node, resource_name, canonical: nil)
        priority_map.get(node, resource_name.to_sym, canonical: canonical)
      end

      def set_priority_array(resource_name, priority_array, *filter, &block)
        priority_map.set(resource_name.to_sym, Array(priority_array), *filter, &block)
      end

      # @api private
      def delete_canonical(resource_name, resource_class)
        priority_map.delete_canonical(resource_name, resource_class)
      end

      # @api private
      def list_handlers(*args)
        priority_map.list(*args).flatten(1).uniq
      end

      private

      def priority_map
        require 'chef/node_map'
        @priority_map ||= Chef::NodeMap.new
      end
    end
  end
end
