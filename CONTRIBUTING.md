# Contributing

中文说明在下方。

## Issue or pull request

- **Issue** — bug, feature idea, or usage question. No code required.
- **Pull request** — you already have a change to merge. Link the Issue when one exists.
- Do not open an empty PR to report a problem.

Use the Issue form on GitHub. Blank issues are turned off so reports stay in the right bucket.

## Scope

This project only helps with a Mac you own, or a target you are authorized to test.

It will not accept:

- Detection bypass, DRM, anti-cheat, payment or access-control circumvention
- A global Gatekeeper off switch
- FairPlay decryption tutorials, procedures or tooling
- Bundling, downloading, caching or mirroring third-party `.deb` / `.dylib` / framework payloads
- Claims that a result is “compatible” or “bypassed” before it is verified on the target device

Such Issues and PRs will be closed.

## Pull requests

1. Fork and branch from `master`.
2. Keep the change focused. One problem per PR.
3. Run `swift test` (and `swift build` if you touched the app target).
4. Fill in the PR template. CI must pass before merge.

Review is requested automatically (`CODEOWNERS`). Maintainers can still push to `master` directly; incoming PRs need a green `build` check.

## Security

Do not file a public Issue for a vulnerability. See [SECURITY.md](SECURITY.md).

## License

By contributing, you license your work under the [GNU GPL-3.0](LICENSE) that covers this repository.

---

## 中文

- **Issue** 用来反馈问题和提需求，不必附带代码。
- **PR** 用来提交已经写好的改动。有对应 Issue 就写上 `Fixes #编号`。
- 不要用空 PR 当反馈箱。

只处理你自己的 Mac，或已获授权的目标。检测绕过、DRM、反作弊、支付或访问控制规避、全局关闭 Gatekeeper、FairPlay 脱壳、捆绑或镜像第三方二进制，一律不接受。

外来 PR 会自动请维护者看；合并前需要 CI 的 `build` 通过。安全问题请走 [SECURITY.md](SECURITY.md)，不要开公开 Issue。

贡献默认按 [GNU GPL-3.0](LICENSE) 授权给本项目。
