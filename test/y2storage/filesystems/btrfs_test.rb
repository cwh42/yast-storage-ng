#!/usr/bin/env rspec
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

require_relative "../spec_helper"
require "y2storage"

describe Y2Storage::Filesystems::Btrfs do
  before do
    fake_scenario(scenario)
  end

  let(:scenario) { "mixed_disks_btrfs" }

  let(:blk_device) { Y2Storage::BlkDevice.find_by_name(fake_devicegraph, dev_name) }

  let(:dev_name) { "/dev/sda2" }

  subject(:filesystem) { blk_device.blk_filesystem }

  describe "#btrfs_subvolumes" do
    it "returns an array of BtrfsSubvolume objects" do
      expect(filesystem.btrfs_subvolumes).to be_a Array
      expect(filesystem.btrfs_subvolumes).to all(be_a(Y2Storage::BtrfsSubvolume))
    end
  end

  describe "#top_level_btrfs_subvolume" do
    it "returns a subvolume with 5 as id" do
      expect(filesystem.top_level_btrfs_subvolume).to be_a Y2Storage::BtrfsSubvolume
      expect(filesystem.top_level_btrfs_subvolume.id).to eq 5

    end
  end

  describe "#default_btrfs_subvolume" do
    it "returns a BtrfsSubvolume object" do
      expect(filesystem.default_btrfs_subvolume).to be_a(Y2Storage::BtrfsSubvolume)
    end

    it "returns the default subvolume" do
      expect(filesystem.default_btrfs_subvolume.path).to eq("@")
    end
  end

  describe "#find_btrfs_subvolume_by_path" do
    context "where exists a subvolume with the searched path" do
      it "returns the subvolume with that path" do
        path = "@/home"
        subvolume = filesystem.find_btrfs_subvolume_by_path(path)

        expect(subvolume).to be_a(Y2Storage::BtrfsSubvolume)
        expect(subvolume.path).to eq(path)
      end
    end

    context "where does not exist a subvolume with the searched path" do
      # TODO: Needed bindings for Storage::BtrfsSubvolumeNotFoundByPath
      xit "returns nil" do
        expect(filesystem.find_btrfs_subvolume_by_path("@/foo")).to be_nil
      end
    end
  end

  describe "#ensure_default_btrfs_subvolume" do
    let(:sda2) { "/dev/sda2" } # default is @
    let(:sdb2) { "/dev/sdb2" } # default is top level

    context "when the requested default path is nil" do
      let(:dev_name) { sda2 }
      let(:path) { nil }

      it "does not create a new subvolume" do
        subvolumes = filesystem.btrfs_subvolumes
        filesystem.ensure_default_btrfs_subvolume(path: path)

        expect(filesystem.btrfs_subvolumes.map(&:path) - subvolumes.map(&:path)).to be_empty
      end

      it "returns the current default subvolume" do
        default = filesystem.default_btrfs_subvolume
        subvolume = filesystem.ensure_default_btrfs_subvolume(path: path)

        expect(subvolume).to eq(default)
      end
    end

    context "when the requested default path is the top level subvolume path" do
      let(:dev_name) { sda2 }
      let(:path) { filesystem.top_level_btrfs_subvolume.path }

      it "does not create a new subvolume" do
        subvolumes = filesystem.btrfs_subvolumes
        filesystem.ensure_default_btrfs_subvolume(path: path)

        expect(filesystem.btrfs_subvolumes.map(&:path) - subvolumes.map(&:path)).to be_empty
      end

      it "returns the top level subvolume" do
        subvolume = filesystem.ensure_default_btrfs_subvolume(path: path)
        expect(subvolume.top_level?).to be(true)
      end

      it "sets the top level subvolume as default subvolume" do
        expect(filesystem.top_level_btrfs_subvolume.default_btrfs_subvolume?).to eq(false)

        filesystem.ensure_default_btrfs_subvolume(path: path)

        expect(filesystem.top_level_btrfs_subvolume.default_btrfs_subvolume?).to eq(true)
      end
    end

    context "when the requested default path does not exist" do
      let(:dev_name) { sdb2 }
      let(:path) { "@" }

      it "creates a new default subvolume with the requested path" do
        expect(filesystem.btrfs_subvolumes.map(&:path)).to_not include(path)

        subvolume = filesystem.ensure_default_btrfs_subvolume(path: path)

        expect(subvolume.default_btrfs_subvolume?).to be(true)
        expect(subvolume.path).to eq(path)
      end
    end

    context "when the requested default path already exists" do
      let(:dev_name) { sda2 }
      let(:path) { "@/home" }

      it "does not create a new subvolume" do
        subvolumes = filesystem.btrfs_subvolumes
        filesystem.ensure_default_btrfs_subvolume(path: path)

        expect(filesystem.btrfs_subvolumes.map(&:path) - subvolumes.map(&:path)).to be_empty
      end

      it "returns the subvolume with the requested path" do
        subvolume = filesystem.ensure_default_btrfs_subvolume(path: path)
        expect(subvolume.path).to eq(path)
      end

      it "sets the subvolume as default subvolume" do
        expect(filesystem.find_btrfs_subvolume_by_path(path).default_btrfs_subvolume?).to eq(false)

        filesystem.ensure_default_btrfs_subvolume(path: path)

        expect(filesystem.find_btrfs_subvolume_by_path(path).default_btrfs_subvolume?).to eq(true)
      end
    end
  end

  describe "#delete_btrfs_subvolume" do
    let(:devicegraph) { Y2Storage::StorageManager.instance.staging }

    context "when the filesystem has a subvolume with the indicated path" do
      let(:path) { "@/home" }

      it "deletes the subvolume" do
        expect(filesystem.btrfs_subvolumes.map(&:path)).to include(path)
        filesystem.delete_btrfs_subvolume(devicegraph, path)
        expect(filesystem.btrfs_subvolumes.map(&:path)).to_not include(path)
      end
    end

    context "when the filesystem has not a subvolume with the indicated path" do
      let(:path) { "@/foo" }

      # FIXME: this is not necessary with bindings for Storage::BtrfsSubvolumeNotFoundByPath
      before do
        allow(filesystem).to receive(:find_btrfs_subvolume_by_path).and_return(nil)
      end

      it "does not delete any subvolume" do
        subvolumes_before = filesystem.btrfs_subvolumes
        filesystem.delete_btrfs_subvolume(devicegraph, path)
        expect(filesystem.btrfs_subvolumes).to eq(subvolumes_before)
      end
    end
  end
end
