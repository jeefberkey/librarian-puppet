require 'librarian/puppet/util'

module Librarian
  module Puppet
    module Source
      module Local
        include Librarian::Puppet::Util

        def install!(manifest)
          manifest.source == self or raise ArgumentError

          if environment.verbose?
            info { "Processing #{manifest.name}" }
          end

          debug { "Installing #{manifest}" }

          name, version = manifest.name, manifest.version
          found_path = found_path(name)

          # We only care about this if we're fetching from a Forge
          if found_path || self.is_a?(Librarian::Puppet::Source::Forge)
            raise Error, "Path for #{name} doesn't contain a puppet module" if found_path.nil?

            unless name.include? '/' or name.include? '-'
              warn { "Invalid module name '#{name}', you should qualify it with 'ORGANIZATION-#{name}' for resolution to work correctly" }
            end

            install_path = environment.install_path.join(module_name(name))
          elsif !repository_cached
            raise Error, "Could not find cached version of #{name} for installation"
          else
            found_path = repository_cache_path
            install_path = environment.project_path + path.to_s
          end

          install_repo = Git::Repository.new(environment,install_path)

          if install_repo.git?
            _install_path = relative_path_to(install_path)

            if environment.git_destructive
              debug { "Performing git hard reset of '#{_install_path}'" }

              install_repo.reset_hard!
              install_repo.clean!
            end

            if install_repo.dirty?
                warn { "#{install_repo.dirty?}, skipping..." }
            else
              # Try to do nicer git operations when possible
              _remote_repo = 'librarian_origin'

              begin
                Librarian::Posix.run!(%W{git remote add #{_remote_repo} #{repository_cache_path}}, :chdir => _install_path)
              rescue Librarian::Posix::CommandFailure => e
                unless e.to_s =~ /already exists/
                  raise Error, "Could not update git repository at #{_install_path}"
                end
              end

              install_repo.fetch!(_remote_repo)

              if environment.verbose?
                warn "Checking out #{ref} in #{_install_path}"
              end
              install_repo.checkout!(ref)

              begin
                _target_ref = ref

                # Handle branches vs absolute refs
                if repository.remote_branch_names[repository.default_remote].include?(_target_ref)
                  _target_ref = "#{repository.default_remote}/#{_target_ref}"
                end

                ff_output = Librarian::Posix.run!(%W{git pull --ff-only #{_remote_repo} #{_target_ref}}, :chdir => _install_path)

                if ff_output =~ /Updating\s+.*\.\.(.*)\s*$/
                  warn { "Updated '#{_install_path}' to #{$1}" }
                end
              rescue Librarian::Posix::CommandFailure => e
                warn { "Fast forward of git repo at '#{_install_path}' failed...skipping" }
              end

              begin
                Librarian::Posix.run!(%W{git remote rm #{_remote_repo}}, :chdir => _install_path)
              rescue Librarian::Posix::CommandFailure => e
                # We don't really care if this fails.
                debug { "Removal of the '#{_remote_repo}' git remote failed" }
              end
            end
          else
            if install_path.exist? && rsync? != true
              debug { "Deleting #{relative_path_to(install_path)}" }
              install_path.rmtree
            end

            install_perform_step_copy!(found_path, install_path)
          end
        end

        def fetch_version(name, extra)
          cache!
          found_path = found_path(name)
          module_version
        end

        def fetch_dependencies(name, version, extra)
          dependencies = Set.new

          if specfile?
            spec = environment.dsl(Pathname(specfile))
            dependencies.merge spec.dependencies
          end

          parsed_metadata['dependencies'].each do |d|
            if environment.use_forge
              gem_requirement = Librarian::Dependency::Requirement.new(d['version_requirement']).to_gem_requirement
              new_dependency = Dependency.new(d['name'], gem_requirement, forge_source)
              dependencies << new_dependency
            end

            dependencies
          end

          dependencies
        end

        def forge_source
          Forge.default
        end

        private

        # Naming this method 'version' causes an exception to be raised.
        def module_version
          if parsed_metadata['version']
            parsed_metadata['version']
          else
            warn { "Module #{to_s} does not have version, defaulting to 0.0.1" }
            '0.0.1'
          end
        end

        def require_puppet
          begin
            require 'puppet'
            require 'puppet/module_tool'
          rescue LoadError
            $stderr.puts <<-EOF
          Unable to load puppet, the puppet gem is required for :git and :path source.
          Install it with: gem install puppet
            EOF
            exit 1
          end
          true
        end

        def evaluate_modulefile(modulefile)
          @@require_puppet ||= require_puppet

          metadata = ::Puppet::ModuleTool::Metadata.new

          # Puppet 4 does not have the class
          unless defined? ::Puppet::ModuleTool::ModulefileReader
            warn { "Can't parse Modulefile in Puppet >= 4.0 and you are using #{Librarian::Puppet::puppet_version}. Ignoring dependencies in #{modulefile}" }
            return metadata
          end

          begin
            ::Puppet::ModuleTool::ModulefileReader.evaluate(metadata, modulefile)
            raise SyntaxError, "Missing version" unless metadata.version
          rescue ArgumentError, SyntaxError => error
            warn { "Unable to parse #{modulefile}, ignoring: #{error}" }
            if metadata.respond_to? :version=
              metadata.version = '0.0.1' # puppet < 3.6
            else
              metadata.update({'version' => '0.0.1'}) # puppet >= 3.6
            end
          end
          metadata
        end

        def parsed_metadata
          if @metadata.nil?
            @metadata = if metadata?
              begin
                JSON.parse(File.read(metadata))
              rescue JSON::ParserError => e
                raise Error, "Unable to parse json file #{metadata}: #{e}"
              end
            elsif modulefile?
              # translate Modulefile to metadata.json
              evaluated = evaluate_modulefile(modulefile)
              {
                'version' => evaluated.version,
                'dependencies' => evaluated.dependencies.map do |dependency|
                  {
                    'name' => dependency.instance_variable_get(:@full_module_name),
                    'version_requirement' => dependency.instance_variable_get(:@version_requirement)
                  }
                end
              }
            else
              {}
            end
            @metadata['dependencies'] ||= []
          end
          @metadata
        end

        def modulefile
          File.join(filesystem_path, 'Modulefile')
        end

        def modulefile?
          File.exists?(modulefile)
        end

        def metadata
          File.join(filesystem_path, 'metadata.json')
        end

        def metadata?
          File.exists?(metadata)
        end

        def specfile
          File.join(filesystem_path, environment.specfile_name)
        end

        def specfile?
          File.exists?(specfile)
        end

        def install_perform_step_copy!(found_path, install_path)
          debug { "Copying #{relative_path_to(found_path)} to #{relative_path_to(install_path)}" }
          cp_r(found_path, install_path)
        end

        def manifest?(name, path)
          return true if path.join('manifests').exist?
          return true if path.join('lib').join('puppet').exist?
          return true if path.join('lib').join('facter').exist?
          debug { "Could not find manifests, lib/puppet or lib/facter under #{path}, maybe it is not a puppet module" }
          true
        end
      end
    end
  end
end
