#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
gollum_dir="$script_dir"
gollum_lib_dir="${GOLLUM_LIB_DIR:-$(cd -- "$script_dir/../gollum-lib" 2>/dev/null && pwd || true)}"
ruby_root="${RUBY_ROOT:-$HOME/.rubies/ruby-master}"
gem_home="${GEM_HOME_OVERRIDE:-}"
service_name="${GOLLUM_SERVICE:-gollum}"
pull=false
precompile=false
restart=false

usage() {
  cat <<'USAGE'
Build and install the sibling gollum-lib and gollum repositories.

Usage: ./build-and-install.sh [options]

Options:
  --pull                 Fast-forward both repositories before building
  --precompile           Recompile Gollum assets before building
  --restart              Restart and show the systemd service after install
  --gollum-lib DIR       Path to the gollum-lib checkout (default: ../gollum-lib)
  --ruby-root DIR        Ruby installation (default: ~/.rubies/ruby-master)
  --gem-home DIR         Install directory (default: Gem.user_dir)
  --service NAME         systemd service for --restart (default: gollum)
  -h, --help             Show this help

Environment equivalents:
  GOLLUM_LIB_DIR, RUBY_ROOT, GEM_HOME_OVERRIDE, GOLLUM_SERVICE

Examples:
  ./build-and-install.sh
  ./build-and-install.sh --pull --precompile --restart
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --pull)
      pull=true
      ;;
    --precompile)
      precompile=true
      ;;
    --restart)
      restart=true
      ;;
    --gollum-lib)
      (($# >= 2)) || die "--gollum-lib requires a directory"
      gollum_lib_dir="$2"
      shift
      ;;
    --ruby-root)
      (($# >= 2)) || die "--ruby-root requires a directory"
      ruby_root="$2"
      shift
      ;;
    --gem-home)
      (($# >= 2)) || die "--gem-home requires a directory"
      gem_home="$2"
      shift
      ;;
    --service)
      (($# >= 2)) || die "--service requires a name"
      service_name="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
  shift
done

ruby_bin="$ruby_root/bin/ruby"
[[ -x "$ruby_bin" ]] || die "Ruby executable not found: $ruby_bin"
[[ -f "$gollum_dir/gollum.gemspec" ]] || die "Not a Gollum checkout: $gollum_dir"
[[ -n "$gollum_lib_dir" && -f "$gollum_lib_dir/gollum-lib.gemspec" ]] ||
  die "gollum-lib checkout not found; use --gollum-lib DIR"

default_gem_home="$(
  env RUBYOPT= RUBYLIB= "$ruby_bin" -rrubygems -e 'print Gem.default_dir'
)"

if [[ -z "$gem_home" ]]; then
  gem_home="$(
    env RUBYOPT= RUBYLIB= "$ruby_bin" -rrubygems -e 'print Gem.user_dir'
  )"
fi

build_path="$ruby_root/bin:/usr/local/bin:/usr/bin:/bin"
install_path="$ruby_root/bin:$gem_home/bin:/usr/local/bin:/usr/bin:/bin"

run_clean() {
  env \
    PATH="$build_path" \
    GEM_HOME="$default_gem_home" \
    GEM_PATH="$default_gem_home" \
    RUBYOPT= \
    RUBYLIB= \
    BUNDLE_PATH= \
    BUNDLE_BIN= \
    BUNDLE_GEMFILE= \
    "$@"
}

run_installed() {
  env \
    PATH="$install_path" \
    GEM_HOME="$gem_home" \
    GEM_PATH="$gem_home:$default_gem_home" \
    RUBYOPT= \
    RUBYLIB= \
    BUNDLE_PATH= \
    BUNDLE_BIN= \
    BUNDLE_GEMFILE= \
    "$@"
}

gem_identity() {
  local gemspec="$1"
  run_clean "$ruby_bin" -rrubygems -e '
    spec = Gem::Specification.load(ARGV.fetch(0))
    abort "Could not load #{ARGV.fetch(0)}" unless spec
    puts "#{spec.name}\t#{spec.version}"
  ' "$gemspec"
}

build_gem() {
  local directory="$1"
  local gemspec_name="$2"
  local name="$3"
  local version="$4"
  local artifact="$directory/$name-$version.gem"

  printf '\nBuilding %s %s...\n' "$name" "$version"
  rm -f -- "$artifact"
  (
    cd -- "$directory"
    run_clean "$ruby_bin" -S gem build "$gemspec_name"
  )
  [[ -f "$artifact" ]] || die "expected package was not built: $artifact"
  built_gem="$artifact"
}

verify_gollum_package() {
  local package="$1"
  run_clean "$ruby_bin" -rrubygems/package -rjson -rtmpdir -e '
    package = Gem::Package.new(ARGV.fetch(0))
    files = package.spec.files
    prefix = "lib/gollum/public/assets/"

    manifests = files.grep(%r{\A#{Regexp.escape(prefix)}[.]sprockets-manifest-.*[.]json\z})
    abort "Gollum package has no Sprockets manifest" if manifests.empty?

    css = files.grep(%r{\A#{Regexp.escape(prefix)}app-.*[.]css\z})
    abort "Gollum package has no compiled app CSS" if css.empty?

    Dir.mktmpdir("gollum-package-") do |directory|
      package.extract_files(directory)
      manifest_path = File.join(directory, manifests.first)
      manifest = JSON.parse(File.read(manifest_path))
      logical_css = manifest.fetch("assets").fetch("app.css")
      app_css = File.join(directory, prefix, logical_css)

      abort "Manifest points to missing app CSS: #{logical_css}" unless File.file?(app_css)

      compiled_css = File.read(app_css)
      abort "Packaged app CSS has no Tip styles" unless compiled_css.include?("gollum-tip")
      abort "Packaged app CSS has no Caution styles" unless compiled_css.include?("gollum-caution")

      puts "Packaged manifest: #{manifests.first}"
      puts "Packaged app CSS:  #{prefix}#{logical_css}"
    end
  ' "$package"
}

source_app_css() {
  run_clean "$ruby_bin" -rjson -e '
    asset_dir = ARGV.fetch(0)
    manifests = Dir.glob(File.join(asset_dir, ".sprockets-manifest-*.json"))
    abort "Gollum asset manifest is missing; run with --precompile" if manifests.empty?

    manifest = JSON.parse(File.read(manifests.first))
    logical_css = manifest.fetch("assets").fetch("app.css")
    app_css = File.join(asset_dir, logical_css)
    abort "Manifest points to missing app CSS: #{logical_css}" unless File.file?(app_css)
    print app_css
  ' "$1"
}

if $pull; then
  printf 'Updating gollum-lib...\n'
  git -C "$gollum_lib_dir" pull --ff-only
  printf 'Updating gollum...\n'
  git -C "$gollum_dir" pull --ff-only
fi

if $precompile; then
  command -v yarn >/dev/null 2>&1 || die "yarn is required by --precompile"
  printf '\nPrecompiling Gollum assets...\n'
  (
    cd -- "$gollum_dir"
    env \
      PATH="$install_path" \
      GEM_HOME="$gem_home" \
      GEM_PATH="$gem_home:$default_gem_home" \
      RUBYOPT= \
      RUBYLIB= \
      "$ruby_bin" -S bundle exec rake precompile
  )
fi

asset_dir="$gollum_dir/lib/gollum/public/assets"
app_css="$(source_app_css "$asset_dir")"
grep -q 'gollum-tip' "$app_css" || die "compiled app CSS does not contain the Tip styles"
grep -q 'gollum-caution' "$app_css" || die "compiled app CSS does not contain the Caution styles"

IFS=$'\t' read -r gollum_lib_name gollum_lib_version < <(
  gem_identity "$gollum_lib_dir/gollum-lib.gemspec"
)
IFS=$'\t' read -r gollum_name gollum_version < <(
  gem_identity "$gollum_dir/gollum.gemspec"
)

source_gollum_lib_version="$(
  run_clean "$ruby_bin" -I"$gollum_lib_dir/lib" -rgollum-lib/version \
    -e 'print Gollum::Lib::VERSION'
)"
[[ "$source_gollum_lib_version" == "$gollum_lib_version" ]] ||
  die "gollum-lib gemspec version $gollum_lib_version does not match runtime version $source_gollum_lib_version"

source_gollum_version="$(
  "$ruby_bin" -e '
    source = File.read(ARGV.fetch(0))
    match = source.match(/^\s*VERSION\s*=\s*["\x27]([^"\x27]+)["\x27]/)
    abort "Could not find Gollum::VERSION" unless match
    print match[1]
  ' "$gollum_dir/lib/gollum.rb"
)"
[[ "$source_gollum_version" == "$gollum_version" ]] ||
  die "Gollum gemspec version $gollum_version does not match runtime version $source_gollum_version"

build_gem \
  "$gollum_lib_dir" gollum-lib.gemspec "$gollum_lib_name" "$gollum_lib_version"
gollum_lib_gem="$built_gem"

build_gem \
  "$gollum_dir" gollum.gemspec "$gollum_name" "$gollum_version"
gollum_gem="$built_gem"

verify_gollum_package "$gollum_gem"

mkdir -p -- "$gem_home/bin"

printf '\nInstalling %s %s...\n' "$gollum_lib_name" "$gollum_lib_version"
run_installed "$ruby_bin" -S gem install \
  --local \
  --ignore-dependencies \
  --no-document \
  --force \
  --install-dir "$gem_home" \
  --bindir "$gem_home/bin" \
  "$gollum_lib_gem"

printf '\nInstalling %s %s...\n' "$gollum_name" "$gollum_version"
run_installed "$ruby_bin" -S gem install \
  --local \
  --ignore-dependencies \
  --no-document \
  --force \
  --install-dir "$gem_home" \
  --bindir "$gem_home/bin" \
  "$gollum_gem"

installed_manifest="$(find "$gem_home/gems/$gollum_name-$gollum_version/lib/gollum/public/assets" \
  -maxdepth 1 -type f -name '.sprockets-manifest-*.json' -print -quit)"
[[ -n "$installed_manifest" ]] || die "installed Gollum gem has no Sprockets manifest"

printf '\nInstalled versions:\n'
versions="$(run_installed "$gem_home/bin/gollum" --versions)"
printf '%s\n' "$versions"
grep -Fq "Gollum $gollum_version" <<<"$versions" || die "installed Gollum version is incorrect"
grep -Fq "gollum-lib $gollum_lib_version" <<<"$versions" || die "installed gollum-lib version is incorrect"

if $restart; then
  printf '\nRestarting %s.service...\n' "$service_name"
  sudo systemctl restart "$service_name"
  sudo systemctl status "$service_name" --no-pager -l
fi

printf '\nBuild and installation completed successfully.\n'
