{
  lib,
  stdenv,
  fetchurl,
  importNpmLock,
  makeWrapper,
  nodejs_24,
  pnpm_11,
  runCommandLocal,
  # npm registry used for both the tarball and the dependency tree. Defaults to
  # the official one; mirrors are passed by the consumer via `.override` (the
  # tarball bytes are identical, so the hash does not change):
  #   (dsh-nix.packages.x86_64-linux.dsh).override { registry = "https://registry.npmmirror.com"; }
  registry ? "https://registry.npmjs.org",
}:

# dsh packaged from the published npm tarball.
#
# Why this repository exists at all: the tarball cannot boot on nixpkgs-built
# Node. dsh 0.2.0+ reaches `internal/modules/esm/loader` through
# `node-addon-require-builtin`, a native addon that decodes machine code in the
# *running* node binary. Its pattern scan only recognizes nodejs.org builds; on
# every nixpkgs-built node the boot dies with
#
#     Unsupported/no-getter (x64 sysv getter is not a recognized this->field accessor)
#
# (nixpkgs#565667, deepseek-harness discussions #1873 / #690). The addon also
# has an escape hatch that upstream uses internally: when `--expose-internals`
# is on, a plain `require(id)` works. nixpkgs' own deepseek-harness package
# patches the TypeScript source to prefer that path — but it builds from a git
# checkout pinned to an old version.
#
# This package takes the tarball and instead **shadows the addon package**: the
# module `node-addon-require-builtin` is replaced by a two-line shim that tries
# `require(id)` first (when `--expose-internals` is set) and delegates to the
# real addon otherwise. The real addon is moved aside as
# `node-addon-require-builtin-impl`.
#
# That is deliberately a *package-level* substitution rather than a patch of the
# bundled JavaScript: all four consumers (dsh-app-boot, dsh-app-boot's worker
# bootstrap, cordis-plugin-loader, dsh-hmr) resolve the same bare specifier, so
# one shim covers them, and a version bump cannot silently miss a fifth call
# site. The `installCheckPhase` boots a real profile, so drift is caught at
# build time rather than at 3am on the NAS.
let
  version = "0.2.2-rc.1";

  reg = lib.removeSuffix "/" registry;

  src = fetchurl {
    url = "${reg}/@deepseek-ai/dsh/-/dsh-${version}.tgz";
    hash = "sha256-rSGWiu0DN6MmuFNQeiOzDqy77E1nqwfztv3mm3WxnNY=";
  };

  # 依赖树来自 npm/package-lock.json（scripts/gen-lock.py 生成）。
  # 那份 lock 的 "resolved" 指向官方 registry；换源时只改 host，
  # integrity 不动 —— 镜像给的包若与官方不同，npm 自己会校验失败。
  npmRoot =
    if reg == "https://registry.npmjs.org" then
      ../npm
    else
      runCommandLocal "dsh-npm-root" { } ''
        mkdir -p $out
        cp ${../npm/package.json} $out/package.json
        sed 's|https://registry.npmjs.org|${reg}|g' ${../npm/package-lock.json} > $out/package-lock.json
      '';

  # 覆盖 node-addon-require-builtin 的 shim。作为一个正常包安装进
  # node_modules，因此裸说明符解析天然命中它。
  addonShim = runCommandLocal "node-addon-require-builtin-shim" { } ''
    mkdir -p $out/lib/node_modules/node-addon-require-builtin
    cat > $out/lib/node_modules/node-addon-require-builtin/package.json <<'JSON'
    {
      "name": "node-addon-require-builtin",
      "version": "0.0.0-nix-shim",
      "description": "Prefers plain require under --expose-internals; delegates to the native addon otherwise.",
      "main": "index.js"
    }
    JSON
    cat > $out/lib/node_modules/node-addon-require-builtin/index.js <<'JS'
    // Prefer a plain require of Node internals when the launcher passes
    // --expose-internals; fall back to the native addon otherwise.
    //
    // The addon decodes machine code in the running node binary to find
    // internal/modules/esm/loader, and only recognizes nodejs.org builds, so on
    // Nix-built node it throws Unsupported/no-getter and every profile boot
    // dies. Requiring internals directly is the path upstream itself uses when
    // the flag is present (see vendor/loader/src/internal.ts).
    const impl = require('node-addon-require-builtin-impl');

    module.exports = {
      requireBuiltin(id) {
        if (process.execArgv.includes('--expose-internals')) {
          try {
            return require(id);
          } catch {}
        }
        return impl.requireBuiltin(id);
      },
    };
    JS
  '';
in
stdenv.mkDerivation {
  pname = "dsh";
  inherit version src;

  npmDeps = importNpmLock { npmRoot = npmRoot; };

  nativeBuildInputs = [
    nodejs_24
    makeWrapper
    importNpmLock.npmConfigHook
  ];

  # Native addons (node-pty, koffi) build with node-gyp/cnoke during the build,
  # so their ABI matches the runtime node exactly — no separate prebuilt step.
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  # The tarball ships compiled output; npmConfigHook still fetches and links the
  # dependency tree, and the postinstall scripts build the two native addons.
  dontBuild = true;
  dontStrip = true;

  # `dsh plugin` runs pnpm against $DSH_HOME/profiles/<name>, so pnpm has to be
  # on PATH at runtime.
  postInstall = ''
    pkgdir="$out/lib/node_modules/@deepseek-ai/dsh"

    # Shadow the addon. `-impl` keeps the real implementation resolvable from
    # the shim; every other package still sees the bare specifier.
    mv "$pkgdir/node_modules/node-addon-require-builtin" \
       "$pkgdir/node_modules/node-addon-require-builtin-impl"
    cp -r ${addonShim}/lib/node_modules/node-addon-require-builtin \
          "$pkgdir/node_modules/node-addon-require-builtin"
    chmod -R u+w "$pkgdir/node_modules/node-addon-require-builtin"
  '';

  installPhase = ''
    runHook preInstall

    pkgdir="$out/lib/node_modules/@deepseek-ai/dsh"
    mkdir -p "$out/lib/node_modules/@deepseek-ai" "$out/bin"

    # Keep npm's layout: the bundle resolves its own dependencies by bare
    # specifier from the package directory.
    cp -R . "$pkgdir"

    makeWrapper ${nodejs_24}/bin/node "$out/bin/dsh" \
      --add-flags "--expose-internals $pkgdir/lib/bin.js" \
      --prefix PATH : ${lib.makeBinPath [ nodejs_24 pnpm_11 ]}

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    export HOME=$TMPDIR DSH_HOME=$TMPDIR/dsh-home
    $out/bin/dsh --version

    # Compose the plugin tree: this is the exact path that dies on the addon.
    $out/bin/dsh web --dump-config > /dev/null

    # Boot for real and wait for the authenticated launch URL. A silent
    # regression in the shim would otherwise only show up on the deployment.
    $out/bin/dsh web --host 127.0.0.1 --port 0 --no-open > server.log 2>&1 &
    pid=$!
    trap 'kill $pid 2>/dev/null || true' EXIT
    for _ in $(seq 1 60); do
      if grep -q 'http://127.0.0.1:[0-9]\+/?token=' server.log; then break; fi
      sleep 1
    done
    grep -q 'http://127.0.0.1:[0-9]\+/?token=' server.log || {
      echo "dsh web did not print a launch URL" >&2
      cat server.log >&2
      exit 1
    }
  '';

  meta = {
    description = "DeepSeek Harness (dsh): plugin-based AI agent harness (npm bundle)";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    license = lib.licenses.mit;
    mainProgram = "dsh";
    platforms = lib.platforms.unix;
  };
}
