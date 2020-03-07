Plugins is a [Nim](https://nim-lang.org/) package that provides a shared library based plugin system

Detailed documentation [here](https://genotrance.github.io/plugins/theindex.html).

__Installation__

Plugins can be installed via [Nimble](https://github.com/nim-lang/nimble):

```bash
nimble install https://github.com/genotrance/plugins
```

This will download and install `plugins` in the standard Nimble package location, typically `~/.nimble`. Once installed, it can be imported into any Nim program.

__Usage__

Detailed module documentation is available [here](https://genotrance.github.io/plugins/theindex.html). The [plugins](https://genotrance.github.io/plugins/plugins.html) module should be used in the main application and the [api](https://genotrance.github.io/plugins/api.html) module should be used in each plugin.

See the `tests` directory for an example of a main application and plugins.

__Feedback__

Plugins is a work in progress and any feedback or suggestions are welcome. It is hosted on [GitHub](https://github.com/genotrance/plugins) with an MIT license so issues, forks and PRs are most appreciated.
