#!/usr/bin/env rspec
# Copyright (c) [2018] SUSE LLC
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
# find current contact information at www.suse.com

require_relative "../test_helper"

require "cwm/rspec"
require "y2partitioner/widgets/visual_device_graph"
require "y2partitioner/widgets/overview"

describe Y2Partitioner::Widgets::VisualDeviceGraph do
  before do
    devicegraph_stub("complex-lvm-encrypt")
  end

  let(:device_graph) { Y2Partitioner::DeviceGraphs.instance.current }
  let(:pager) { Y2Partitioner::Widgets::OverviewTreePager.new("hostname") }

  subject(:widget) { described_class.new(device_graph, pager) }

  include_examples "CWM::CustomWidget"

  describe "#handle" do
    before do
      Y2Storage::Filesystems::Nfs.create(device_graph, "new", "/device")
      allow(Yast::UI).to receive(:QueryWidget).and_return item
    end

    context "when there is no device with the clicked sid" do
      # The first sid used by libstorage-ng is 42. And when a devicegraph is loaded from a yaml file,
      # sids are continuously increasing after each new load. So using a big sid number to represent a
      # missing device is not safe enough. Such big number could be reached if several yaml files are
      # loaded before this test. The safer solution is to use a sid less than 42 (for example, 1).
      let(:item) { "1" }

      it "doesn't change the current section" do
        expect(pager).to_not receive(:switch_page)
        widget.handle
      end
    end

    context "when an NFS device is clicked" do
      let(:item) { device_graph.nfs_mounts.first.sid.to_s }

      it "switches to the NFS section" do
        expect(pager).to receive(:switch_page) do |page|
          expect(page.label).to eq "NFS"
        end
        widget.handle
      end
    end

    context "when a device with its own page is clicked" do
      let(:partition) { device_graph.find_by_name("/dev/sda1") }
      let(:item) { partition.sid.to_s }

      it "switches to the corresponding section" do
        expect(pager).to receive(:switch_page) do |page|
          expect(page.label).to eq "sda1"
        end
        widget.handle
      end
    end

    context "when a file system is clicked" do
      let(:device) { device_graph.find_by_name("/dev/vg0/lv1") }
      let(:item) { device.filesystem.sid.to_s }

      it "switches to the section of the host device" do
        expect(pager).to receive(:switch_page) do |page|
          expect(page.label).to eq "lv1"
        end
        widget.handle
      end
    end
  end

  describe "#init" do
    it "updates the content of the graph widget" do
      allow(Yast::Term).to receive(:new)
      expect(Yast::Term).to receive(:new).with(:Graph, any_args)
      expect(Yast::UI).to receive(:ReplaceWidget)
      widget.init
    end
  end
end
