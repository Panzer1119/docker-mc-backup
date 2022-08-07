# Changelog

All notable changes to this project will be documented in this file. See [commit-and-tag-version](https://github.com/absolute-version/commit-and-tag-version) for commit guidelines.

## [1.1.0](https://github.com/Panzer1119/docker-mc-backup/compare/v1.0.0...v1.1.0) (2022-08-07)


### Features

* **borg:** implement retention policy Grandfather-father-son ([efcfb37](https://github.com/Panzer1119/docker-mc-backup/commit/efcfb375bcb2f1e71d19d0ff4911b44a421c7fc4))


### Bug Fixes

* **borg:** prefix when pruning with borg ([9e10bd0](https://github.com/Panzer1119/docker-mc-backup/commit/9e10bd015fde84eb83c9ffe23c841c36ead2a724))

## 1.0.0 (2022-08-05)


### Features

* **borg:** create borg_common_options and borg_options in borgs init method ([bb4f6ac](https://github.com/Panzer1119/docker-mc-backup/commit/bb4f6accf958ffcf1b5723750bdd2f9541a7752e))
* **borg:** create new backup method borg ([3ccce0b](https://github.com/Panzer1119/docker-mc-backup/commit/3ccce0ba761d3367dbd4c238679f64995c2c019e))
* **borg:** implement new backup method borg ([fb911d9](https://github.com/Panzer1119/docker-mc-backup/commit/fb911d90b6c1c4ec03797a16af54948f163ca868))
* **borg:** set /borg as default value for env variable BORG_REPO ([a98068e](https://github.com/Panzer1119/docker-mc-backup/commit/a98068ef003a532567669b6e48d4708fb57fe86d))
* **borg:** use borg_common_options and borg_options in borgs backup and prune methods ([e4a3793](https://github.com/Panzer1119/docker-mc-backup/commit/e4a37938999441cb7ef8e2ba72e695af3da7ffaf))
* **restic:** add options to finetune restic ([#13](https://github.com/Panzer1119/docker-mc-backup/issues/13)) ([368a30e](https://github.com/Panzer1119/docker-mc-backup/commit/368a30e1247ab8aaf672b59ed5fd59c6eb6a745b))


### Bug Fixes

* **borg:** prefix when pruning with borg ([6e96ebd](https://github.com/Panzer1119/docker-mc-backup/commit/6e96ebdb5249d7f2a80446cd494ce82c20926a08))
* **borg:** use utc when generating timestamp for the archive name ([0ba5780](https://github.com/Panzer1119/docker-mc-backup/commit/0ba578060a2a28304c9e9853722171a283dc1918))
* ensured date in filenames honors TZ ([feeecee](https://github.com/Panzer1119/docker-mc-backup/commit/feeeceece1b4a3ca4307a00fa63dc4aef84c34c2)), closes [#42](https://github.com/Panzer1119/docker-mc-backup/issues/42)
