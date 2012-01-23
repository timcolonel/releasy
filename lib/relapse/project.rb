require 'relapse/dsl_wrapper'
require 'relapse/builders'
require 'relapse/archivers'
require "relapse/mixins/has_archivers"

module Relapse
  # @attr underscored_name [String] Project name underscored (as used in file names), which will be derived from {#name}, but can be manually set.
  # @attr underscored_version [String] Version number, underscored so it can be used in file names, which will be derived from {#version}, but can be manually set.
  # @attr executable [String] Name of executable to run (defaults to 'bin/<underscored_name>')
  # @attr_reader folder_base [String] The path to the folder to create - All variations of output will be based on extending this path.
  class Project
    include Rake::DSL
    include Mixins::HasArchivers

    DEFAULT_PACKAGE_FOLDER = "pkg"

    attr_writer :underscored_name, :underscored_version, :executable

    # @return [Boolean] Make the tasks give more detailed output.
    attr_writer :verbose
    # @return [String] Name of the application, such as "My Application".
    attr_accessor :name
    # @return [Array<String>] List of files to include in package.
    attr_accessor :files
    # @return [Array<String>] Files which should always be copied into the archive folder root, so they are always visible to the user. e.g readme, change-log and/or license files.
    attr_accessor :exposed_files
    # @return [String] Version number as a string (for example, "1.2.0").
    attr_accessor :version
    # @return [String] Folder to output to (defaults to 'pkg/')
    attr_accessor :output_path

    # Verbosity of the console output.
    # @return [Boolean] True to make the tasks output more information.
    def verbose?; @verbose; end

    def to_s; "<#{self.class}#{name ? " #{name}" : ""}#{version ? " #{version}" : ""}>"; end

    def underscored_name
      if @underscored_name or @name.nil?
        @underscored_name
      else
        @name.strip.downcase.gsub(/[^a-z0-9_\- ]/i, '').split(/[\-_ ]+/).join("_")
      end
    end

    def underscored_version
      if @underscored_version or @version.nil?
        @underscored_version
      else
        @version.gsub(".", "_")
      end
    end

    def executable
      if @executable or underscored_name.nil?
        @executable
      else
        "bin/#{underscored_name}"
      end
    end

    # Can be used with or without a block to generate building and packaging tasks.
    #
    # @example
    #     # Using a block, the API is more terse and the tasks are automatically generated
    #     # when the block is closed.
    #     Relapse::Project.new do
    #       name "My Application"
    #       version "1.2.4"
    #       add_build :source do
    #         add_archive :zip
    #       end
    #     end
    #
    # @example
    #     # Without using blocks.
    #     project = Relapse::Project.new
    #     project.name = "My Application"
    #     project.version = "1.2.4"
    #     output = project.add_build :source
    #     output.add_archive :zip
    #     project.generate_tasks
    #
    def initialize(&block)
      super()

      @builders = []
      @links = {}
      @files = []
      @exposed_files = []
      @output_path = DEFAULT_PACKAGE_FOLDER
      @verbose = true

      @name = @underscored_name = @underscored_version = nil
      @version = @executable = nil

      if block_given?
        DSLWrapper.new(self, &block)
        generate_tasks
      end
    end



    # Add a type of output to produce. Must define at least one of these.
    #
    # @param type [:osx_app, :source, :windows_folder, :windows_folder_from_ruby_dist, :windows_installer, :windows_standalone]
    # @return [Project] self
    def add_build(type, &block)
      raise ArgumentError, "Unsupported output type #{type}" unless Builders.has_type? type
      raise ConfigError, "Already have output #{type.inspect}" if @builders.any? {|b| b.type == type }

      builder = Builders[type].new(self)
      @builders << builder

      DSLWrapper.new(builder, &block) if block_given?

      builder
    end

    # Add a link file to be included in the win32 releases. Will create the file _title.url_ for you.
    #
    # @param url [String] Url to link to.
    # @param title [String] Name of file to create.
    # @return [Project] self
    def add_link(url, title)
      @links[url] = title

      self
    end

    # Generates all tasks required by the user. Automatically called at the end of the block, if {#initialize} is given a block.
    def generate_tasks
      raise ConfigError, "Must specify at least one valid output for this OS with #add_build before tasks can be generated" if @builders.empty?

      # Even if there are builders specified, none may work on this platform.
      return if active_builders.empty?

      build_outputs = []
      build_groups = Hash.new {|h, k| h[k] = [] }

      active_builders.each do |builder|
        builder.generate_tasks
        task_name = "build:#{builder.type.to_s.tr("_", ":")}"

        if builder.type.to_s =~ /_/
          task_group = builder.send :task_group
          build_groups[task_group] << task_name
          build_outputs << "build:#{task_group}"
        else
          build_outputs << task_name
        end
      end

      build_groups.each_pair do |group, tasks|
        desc "Build all #{group} outputs"
        task "build:#{group}" => tasks
      end

      desc "Build all outputs"
      task "build" => build_outputs

      generate_archive_tasks

      self
    end


    def folder_base
      File.join(output_path, "#{underscored_name}#{version ? "_#{underscored_version}" : ""}")
    end

    protected
    # Only allow access to this from Builder
    # @return [Hash]
    def links; @links; end

    protected
    # @return [Array<Builder>]
    def active_builders
      @builders.find_all(&:valid_for_platform?)
    end

    protected
    # Generates the general tasks for compressing folders.
    def generate_archive_tasks
      return if active_builders.empty?

      windows_tasks = []
      osx_tasks = []
      top_level_tasks = []
      active_builders.each do |builder|
        output_task = builder.type.to_s.sub '_', ':'

        archivers = active_archivers(builder)
        archivers.each do |archiver|
          archiver.generate_tasks output_task, builder.folder
        end

        desc "Package all #{builder.type}"
        task "package:#{output_task}" => archivers.map {|c| "package:#{output_task}:#{c.type}" }

        case output_task
          when /^windows:/
            windows_tasks << "package:#{output_task}"
            top_level_tasks << "package:windows" unless top_level_tasks.include? "package:windows"
          when /^osx:/
            osx_tasks << "package:#{output_task}"
            top_level_tasks << "package:osx" unless top_level_tasks.include? "package:osx"
          else
            top_level_tasks << "package:#{output_task}"
        end
      end

      unless windows_tasks.empty?
        desc "Package all Windows"
        task "package:windows" => windows_tasks
      end

      unless osx_tasks.empty?
        desc "Package all OS X"
        task "package:osx" => osx_tasks
      end

      desc "Package all"
      task "package" => top_level_tasks

      self
    end

    protected
    def active_archivers(builder)
      # Use archivers specifically set on the builder and those set globally that aren't on the builder.
      archivers = builder.send(:active_archivers)
      archiver_types = archivers.map(&:type)

      archivers + super().reject {|a| archiver_types.include? a.type }
    end
  end
end