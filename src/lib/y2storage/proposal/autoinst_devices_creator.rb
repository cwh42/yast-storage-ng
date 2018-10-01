#!/usr/bin/env ruby
#
# encoding: utf-8

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

require "y2storage/proposal/partitions_distribution_calculator"
require "y2storage/proposal/partition_creator"
require "y2storage/proposal/md_creator"
require "y2storage/proposal/autoinst_creator_result"
require "y2storage/exceptions"

module Y2Storage
  module Proposal
    # Class to create and reuse devices during the AutoYaST proposal, based
    # on the information contained in the profile.
    #
    # ## Comparison with the guided proposal
    #
    # This class receives a devicegraph in which the previous devices have
    # already been deleted or resized according to the AutoYaST profile. This
    # is different from the guided setup equivalent step, in which the minimal
    # amount of existing devices are deleted/resized on demand while trying to
    # allocate the planned devices.
    #
    # ## Reducing planned devices when there is not enough space
    #
    # Another key difference with the guided proposal is that, when there is
    # not enough space (for partitions or logical volumes), it will do a second
    # attempt reducing all planned devices proportionally. In order to do so,
    # it will remove the min_size limit (setting it to just 1 byte) and,
    # additionally, it will set a proportional weight for every partition (see
    # {#flexible_devices}).
    #
    # Although this approach may not produce the optimal results, it is less
    # intrusive and easier to maintain than other alternatives. Bear in mind
    # that AutoYaST does not expect complex scenarios (like multiple disks with
    # several gaps), so the result should be good enough.
    #
    # If we were aiming for the optimal devices distribution, we should look at
    # {Y2Storage::Planned::PartitionsDistribution#assigned_space} and follow
    # the same approach (reducing min_size and setting a proportional weight)
    # when it is not possible to place the devices in the given free space. But
    # we would also need to do further changes, like skipping some checks when
    # running in this flexible mode.
    class AutoinstDevicesCreator
      include Yast::Logger

      # Constructor
      #
      # @param original_graph [Devicegraph] Devicegraph to be used as starting point
      def initialize(original_graph)
        @original_graph = original_graph
      end

      # Devicegraph including all the specified planned devices
      #
      # @param planned_devices [Planned::DevicesCollection] Devices to create/reuse
      # @param disk_names [Array<String>] Disks to consider
      #
      # @return [AutoinstCreatorResult] Result with new devicegraph in which all the
      #   planned devices have been allocated
      def populated_devicegraph(planned_devices, disk_names)
        # Process planned partitions
        log.info "planned devices = #{planned_devices.to_a.inspect}"
        log.info "disk names = #{disk_names.inspect}"

        # Process planned partitions
        parts_to_create, parts_to_reuse, creator_result =
          process_partitions(planned_devices, disk_names)

        # Process planned stray block devices (Xen virtual partitions)
        planned_stray_devs = process_stray_devs(planned_devices, creator_result.devicegraph)

        # Add planned stray block devices to reuse list so they can be considered for lvm
        # and raids later on.
        #
        # FIXME: When a disk device is used as PV (indicated as partition with number 0
        # in the autoyast profile), a Stray Block Device is planned for it. Think about
        # a better solution (maybe by creating a Planned::PV ?).
        devs_to_reuse = parts_to_reuse + planned_stray_devs

        # Process planned Mds
        mds_to_create, _mds_to_reuse, creator_result =
          process_mds(planned_devices, devs_to_reuse, creator_result)

        # Process planned Vgs
        planned_vgs, creator_result =
          process_vgs(planned_devices, devs_to_reuse, creator_result)

        Y2Storage::Proposal::AutoinstCreatorResult.new(
          creator_result, parts_to_create + mds_to_create + planned_vgs
        )
      end

    protected

      # @return [Devicegraph] Original devicegraph
      attr_reader :original_graph

      # Finds the best distribution for the given planned partitions
      #
      # @param planned_partitions [Array<Planned::Partition>] Partitions to add
      # @param disk_names         [Array<String>]             Names of disks to consider
      #
      # @see Proposal::PartitionsDistributionCalculator#best_distribution
      def best_distribution(planned_partitions, disk_names)
        disks = original_graph.disk_devices.select { |d| disk_names.include?(d.name) }
        spaces = disks.map(&:free_spaces).flatten

        calculator = Proposal::PartitionsDistributionCalculator.new
        dist = calculator.best_distribution(planned_partitions, spaces)
        return dist if dist

        # Second try with more flexible planned partitions
        calculator.best_distribution(flexible_devices(planned_partitions), spaces)
      end

    private

      # Process planned partitions
      #
      # @param planned_devices [Array<Planned::Device>] Devices to create/reuse
      # @param disk_names [Array<String>] Disks to consider
      #
      # @return [Array<Array<Planned::Partition>, Array<Planned::Partition>, CreatorResult>]
      def process_partitions(planned_devices, disk_names)
        planned_partitions = planned_devices.partitions
        parts_to_reuse, parts_to_create = planned_partitions.partition(&:reuse?)
        creator_result = create_partitions(parts_to_create, disk_names)
        reuse_devices(parts_to_reuse, creator_result.devicegraph)

        [parts_to_create, parts_to_reuse, creator_result]
      end

      # Process planned Mds
      #
      # @param planned_devices [Array<Planned::Device>] Devices to create/reuse
      # @param devs_to_reuse [Array<Planned::Device>] Devices to reuse
      # @param creator_result [CreatorResult] partial result
      #
      # @return [Array<Array<Planned::Md>, Array<Planned::Md>, CreatorResult>]
      def process_mds(planned_devices, devs_to_reuse, creator_result)
        mds_to_reuse, mds_to_create = planned_devices.mds.partition(&:reuse?)
        # TODO: currently it is not possible to use full disks in a RAID
        devs_to_reuse_in_md = reusable_by_md(devs_to_reuse)
        creator_result.merge!(create_mds(mds_to_create, creator_result, devs_to_reuse_in_md))
        mds_to_reuse.each { |i| i.reuse!(creator_result.devicegraph) }

        [mds_to_create, mds_to_reuse, creator_result]
      end

      # Process planned Vgs
      #
      # @param planned_devices [Array<Planned::Device>] Devices to create/reuse
      # @param devs_to_reuse [Array<Planned::Device>] Devices to reuse
      # @param creator_result [CreatorResult] partial result
      #
      # @return [Array<Array<Planned::Md>, Array<Planned::Md>, CreatorResult>]
      def process_vgs(planned_devices, devs_to_reuse, creator_result)
        planned_vgs = planned_devices.vgs
        creator_result.merge!(set_up_lvm(planned_vgs, creator_result, devs_to_reuse))
        vgs_to_reuse = planned_vgs.select(&:reuse?)
        reuse_vgs(vgs_to_reuse, creator_result.devicegraph)

        [planned_vgs, creator_result]
      end

      # Formats and/or mounts the stray block devices (Xen virtual partitions)
      #
      # @param planned_devices [Array<Planned::Device>] all planned devices
      # @param devicegraph     [Devicegraph] devicegraph containing the Xen
      #   partitions to be processed. It will be modified.
      # @return                [Array<Planned::StrayBlkDevice>] all stray block
      #   devices
      def process_stray_devs(planned_devices, devicegraph)
        planned_stray_devs = planned_devices.select { |d| d.is_a?(Planned::StrayBlkDevice) }
        planned_stray_devs.each { |d| d.reuse!(devicegraph) }

        planned_stray_devs
      end

      # Creates planned partitions in the given devicegraph
      #
      # @param new_partitions [Array<Planned::Partition>] Devices to create
      # @param disk_names     [Array<String>]             Disks to consider
      # @return [PartitionCreatorResult]
      def create_partitions(new_partitions, disk_names)
        log.info "Partitions to create: #{new_partitions}"
        primary, non_primary = new_partitions.partition(&:primary)
        parts_to_create = primary + non_primary

        dist = best_distribution(parts_to_create, disk_names)
        raise NoDiskSpaceError, "Could not find a valid partitioning distribution" if dist.nil?
        part_creator = Proposal::PartitionCreator.new(original_graph)
        part_creator.create_partitions(dist)
      end

      # Creates volume groups in the given devicegraph
      #
      # @param vgs             [Array<Planned::LvmVg>]     List of planned volume groups to add
      # @param previous_result [Proposal::CreatorResult]   Starting point
      # @param devs_to_reuse   [Array<Planned::Partition, Planned::StrayBlkDevice>] List of devices
      #   to reuse as Physical Volumes
      # @return                [Proposal::CreatorResult] Result containing the specified volume groups
      def set_up_lvm(vgs, previous_result, devs_to_reuse)
        # log separately to be more readable
        log.info "BEGIN: set_up_lvm: vgs=#{vgs.inspect}"
        log.info "BEGIN: set_up_lvm: previous_result=#{previous_result.inspect}"
        log.info "BEGIN: set_up_lvm: devs_to_reuse=#{devs_to_reuse.inspect}"
        vgs.reduce(previous_result) do |result, vg|
          pvs = previous_result.created_names { |d| d.pv_for?(vg.volume_group_name) }
          pvs += devs_to_reuse.select { |d| d.pv_for?(vg.volume_group_name) }.map(&:reuse_name)
          result.merge(create_logical_volumes(result.devicegraph, vg, pvs))
        end
      end

      # Create volume group in the given devicegraph
      #
      # @param devicegraph [Devicegraph]                    Starting devicegraph
      # @param vg          [Planned::LvmVg]                 Volume group
      # @param pvs         [Planned::Partition,Planned::Md] List of physical volumes
      # @return            [Proposal::CreatorResult] Result containing the specified volume group
      def create_logical_volumes(devicegraph, vg, pvs)
        lvm_creator = Proposal::LvmCreator.new(devicegraph)
        lvm_creator.create_volumes(vg, pvs)
      rescue RuntimeError
        lvm_creator = Proposal::LvmCreator.new(devicegraph)
        new_vg = vg.clone
        new_vg.lvs = flexible_devices(vg.lvs)
        lvm_creator.create_volumes(new_vg, pvs)
      end

      # Reuses partitions or logical volumes for the given devicegraph
      #
      # Shrinking partitions/logical volumes should be processed first in order to free
      # some space for growing ones.
      #
      # @param reused_devices  [Array<Planned::Partition,Planned::LvmLv>] Logical volumes to reuse
      # @param devicegraph     [Devicegraph] Devicegraph to reuse partitions
      def reuse_devices(reused_devices, devicegraph)
        shrinking, not_shrinking = reused_devices.partition { |d| d.shrink?(devicegraph) }
        (shrinking + not_shrinking).each { |d| d.reuse!(devicegraph) }
      end

      # Reuses volume groups for the given devicegraph
      #
      # @param reused_vgs  [Array<Planned::LvmVg>] Volume groups to reuse
      # @param devicegraph [Devicegraph]           Devicegraph to reuse partitions
      def reuse_vgs(reused_vgs, devicegraph)
        reused_vgs.each do |vg|
          vg.reuse!(devicegraph)
          reuse_devices(vg.all_lvs.select(&:reuse?), devicegraph)
        end
      end

      # Creates MD RAID devices in the given devicegraph
      #
      # @param mds             [Array<Planned::Md>]        List of planned MD arrays to create
      # @param previous_result [Proposal::CreatorResult]   Starting point
      # @param devs_to_reuse   [Array<Planned::Partition, Planned::StrayBlkDevice>] List of devices
      #   to reuse.
      # @return                [Proposal::CreatorResult] Result containing the specified MD RAIDs
      def create_mds(mds, previous_result, devs_to_reuse)
        mds.reduce(previous_result) do |result, md|
          md_creator = Proposal::MdCreator.new(result.devicegraph)
          devices = previous_result.created_names { |d| d.raid_name == md.name }
          devices += devs_to_reuse.select { |d| d.raid_name == md.name }.map(&:reuse_name)
          result.merge(md_creator.create_md(md, devices))
        end
      end

      # Return a new planned devices with flexible limits
      #
      # The min_size is removed and a proportional weight is set for every device.
      #
      # @return [Hash<Planned::Partition => Planned::Partition>]
      def flexible_devices(devices)
        devices.map do |device|
          new_device = device.clone
          new_device.weight = device.min_size.to_i
          new_device.min_size = DiskSize.B(1)
          new_device
        end
      end

      # Return devices which can be reused by an MD RAID
      #
      # @param planned_devices [Planned::DevicesCollection] collection of planned devices
      # @return [Array<Planned::Device>]
      def reusable_by_md(planned_devices)
        planned_devices.select { |d| d.is_a?(Planned::StrayBlkDevice) }
      end
    end
  end
end
