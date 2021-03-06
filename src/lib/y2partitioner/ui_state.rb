# Copyright (c) [2017] SUSE LLC
#
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of version 2 of the GNU General Public License as published
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, contact SUSE LLC.
#
# To contact SUSE LLC about this file by physical or electronic mail, you may
# find current contact information at www.suse.com.

module Y2Partitioner
  # Singleton class to keep the position of the user in the UI and other similar
  # information that needs to be rememberd across UI redraws to give the user a
  # sense of continuity.
  class UIState
    include Yast::I18n

    # Constructor
    #
    # Called through {.create_instance}, starts with a blank situation (which
    # means default for each widget will be honored).
    def initialize
      textdomain "storage"

      @candidate_nodes = []
      @open_items = {}
      @overview_tree_pager = nil
    end

    # A reference to the overview tree pager, which is a new instance every dialog redraw. See note
    # in {Dialogs::Main#contents}
    #
    # @return [Widgets::OverviewTreePager]
    attr_accessor :overview_tree_pager

    # Hash listing all the items with children of the tree and specifying whether
    # such item should be expanded (true) or collapsed (false) in the next redraw.
    #
    # @note Only elements with children are stored, for the others the current state
    # is not relevant (not having children, they are neither open or closed).
    #
    # @return [Hash{String => Boolean}]
    attr_reader :open_items

    # Title of the section listing the MD RAIDs
    #
    # @note This is defined in this class as the simplest way to avoid
    #   dependency cycles in the Ruby requires. We might reconsider a more clean
    #   approach in the future.
    #
    # @return [String]
    def md_raids_label
      _("RAID")
    end

    # Title of the LVM section
    #
    # @note See note on {.md_raids_label} about why this looks misplaced.
    #
    # @return [String]
    def lvm_label
      _("Volume Management")
    end

    # Title of the bcache section
    #
    # @note See note on {.md_raids_label} about why this looks misplaced.
    #
    # @return [String]
    def bcache_label
      _("Bcache")
    end

    # Title of the Btrfs section
    #
    # @note See note on {.md_raids_label} about why this looks misplaced.
    #
    # @return [String]
    def btrfs_filesystems_label
      _("Btrfs")
    end

    # @return [Integer, nil] if a row must be selected in a table with devices,
    #   this returns the sid of the associated device
    attr_reader :row_sid

    # Method to be called when the user decides to visit a given page by
    # clicking in one node of the general tree.
    #
    # It remembers the decision so the user is taken back to a sensible point of
    # the tree (very often the last he decided to visit) after redrawing.
    #
    # @param [CWM::Page] page associated to the tree node
    def go_to_tree_node(page)
      self.candidate_nodes =
        if page.respond_to?(:device)
          device_page_candidates(page)
        else
          [page.label]
        end
      # Landing in a new node, so invalidate previous details about position
      # within a node, they no longer apply
      self.tab = nil
    end

    # Method to be called when the user switches to a tab within a tree node.
    #
    # It remembers the decision so the same tab is showed in case the user stays
    # in the same node after redrawing.
    #
    # @param [CWM::Page, String] page associated to the tab (or just its label)
    def switch_to_tab(page)
      self.tab = page.respond_to?(:label) ? page.label : page
    end

    # Method to be called when the user operates in a row of a table of devices
    # or creates a new device.
    #
    # @param device [Y2Storage::Device, Integer] sid or device object
    def select_row(device)
      sid = device.respond_to?(:sid) ? device.sid : device
      self.row_sid = sid
    end

    # Select the page to open in the general tree after a redraw
    #
    # If the first candidate page/node (the "current" one) is not available anymore, the tab name
    # and selected row are cleared. See #tab=
    #
    # @param pages [Array<CWM::Page>] all the pages in the tree
    # @return [CWM::Page, nil] the page to be opened; the initial one when nil
    def find_tree_node(pages)
      # candidate_nodes can be empty if the user has not left the overview page yet. So, do nothing
      return nil if candidate_nodes.empty?

      candidate_nodes.each.with_index do |candidate, idx|
        result = pages.find { |page| matches?(page, candidate) }
        if result
          # If the first candidate is not available anymore (likely, it was deleted),
          # we had to use one of the fallbacks and the tab name is not longer trustworthy
          self.tab = nil unless idx.zero?
          return result
        end
      end

      # For some reason none candidate is available. Let's reset the tab name.
      self.tab = nil

      nil
    end

    # Select the tab to open within the node after a redraw
    #
    # @param pages [Array<CWM::Page>] pages for all the possible tabs
    # @return [CWM::Page, nil]
    def find_tab(pages)
      return nil unless tab

      pages.find { |page| page.label == tab }
    end

    # Stores the ids of the tree items that are open
    def save_open_items
      return unless overview_tree_pager

      @open_items = overview_tree_pager.open_items
    end

    protected

    # Useful to know where to place the user within the general tree in the next redraw
    #
    # It could hold both, devices id (sid, Integer) or pages labels (String).
    #
    # @see #find_tree_node
    #
    # @return [Array<Integer, String>]
    attr_accessor :candidate_nodes

    # Concrete tab within the current node to show in the next redraw
    # @return [String, nil]
    attr_reader :tab

    # @see #row_sid
    attr_writer :row_sid

    # @see #tab
    def tab=(tab)
      @tab = tab
      # If the user switched to a new tab, invalidate details about the inner table
      self.row_sid = nil
    end

    # List of candidate nodes to go back after opening a device view in the tree
    #
    # @return [Array<Integer, String>]
    def device_page_candidates(page)
      device = page.device
      [device.sid, device_page_parent(device)].compact
    end

    # @see #device_page_candidates
    #
    # @return [Integer, String, nil] nil if there is no parent tree entry
    def device_page_parent(device)
      if device.is?(:partition)
        device.partitionable.sid
      elsif device.is?(:lvm_lv)
        device.lvm_vg.sid
      else
        device_page_section(device)
      end
    end

    # @see #device_page_candidates
    # @see #device_page_parent
    #
    # @return [Integer, String, nil] nil if there is no parent tree entry
    def device_page_section(device)
      if device.is?(:md)
        md_raids_label
      elsif device.is?(:lvm_vg)
        lvm_label
      elsif device.is?(:bcache)
        bcache_label
      elsif device.is?(:btrfs)
        btrfs_filesystems_label
      end
    end

    # Whether the given page matches with the candidate tree node
    #
    # @param page [CWM::Page]
    # @param candidate [Integer, String]
    # @return boolean
    def matches?(page, candidate)
      if candidate.is_a?(Integer)
        page.respond_to?(:device) && page.device.sid == candidate
      else
        page.label == candidate
      end
    end

    class << self
      # Singleton instance
      def instance
        create_instance unless @instance
        @instance
      end

      # Enforce a new clean instance
      def create_instance
        @instance = new
      end

      # Make sure only .instance and .create_instance can be used to
      # create objects
      private :new, :allocate
    end
  end
end
