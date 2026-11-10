# abyss

自用越狱软件源，由 GitHub Pages 发布。

源地址：

```
https://aby7557.github.io
```

- `debs/`：软件包，文件名一律为 `<Package>_<Version>_<Architecture>.deb`
- `depictions/<包标识>/`：可选的网页描述与图标
- `scripts/update-repository.sh`：生成 `Packages`、`Packages.gz/.bz2/.xz` 与 `Release`
- `.github/workflows/update-repository.yml`：每次推送到 `main` 后自动索引并发布到 Pages

索引与 `_site/` 都由工作流生成，不要提交。新增软件包：把 deb 放进 `debs/`，提交并推送即可。
