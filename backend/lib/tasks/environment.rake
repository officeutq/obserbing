# frozen_string_literal: true

namespace :environment do
  desc "Verify the local PostgreSQL and pgvector versions without enabling extensions"
  task verify: :environment do
    connection = ActiveRecord::Base.connection
    server_version = connection.select_value("SHOW server_version")
    server_version_num = connection.select_value("SHOW server_version_num").to_i
    pgvector_version = connection.select_value(<<~SQL.squish)
      SELECT default_version
      FROM pg_available_extensions
      WHERE name = 'vector'
    SQL

    abort "PostgreSQL 18 or newer is required (found #{server_version})" if server_version_num < 180_000
    abort "pgvector 0.8.1 must be available (found #{pgvector_version || 'none'})" unless pgvector_version == "0.8.1"

    puts "database_connection=ok"
    puts "postgresql_server_version=#{server_version}"
    puts "pgvector_available_version=#{pgvector_version}"
    puts "pgvector_installed=#{connection.extension_enabled?("vector")}"
  end
end
