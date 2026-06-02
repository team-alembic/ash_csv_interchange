import Config

config :git_ops,
  mix_project: AshCsvInterchange.MixProject,
  changelog_file: "CHANGELOG.md",
  repository_url: "https://github.com/team-alembic/ash_csv_interchange",
  types: [
    tidbit: [
      hidden?: true
    ],
    important: [
      header: "Important Changes"
    ]
  ],
  manage_mix_version?: true,
  manage_readme_version: "README.md",
  version_tag_prefix: "v"

# The test suite registers its fixture domains under the library's own OTP
# app, so point the host-app resolver at :ash_csv_interchange. Consuming
# applications set this to their own app instead (see the AshCsvInterchange
# moduledoc). Dependency config files aren't loaded by consumers, so this is
# scoped to the library's own dev/test runs.
if config_env() == :test do
  config :ash_csv_interchange, otp_app: :ash_csv_interchange

  # The fixture resources are Ash-backed, and Ash logs every data-layer write
  # at :debug. Quiet that so test output stays readable.
  config :logger, level: :warning
end
