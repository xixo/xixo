const {spawn} = require('child_process');
const path = require('path');
const jsonParser = require('stream-json');
const StreamObject = require('stream-json/streamers/StreamObject');

let timeout;
let cache = [];

const decorate = ([name, entry]) => {
  const packageJSON = `${name}/package.json`;

  let packageData = {};
  let packageDir;
  let packagePath;

  try {
    packagePath = require.resolve(packageJSON);
    packageData = require(packageJSON);
    packageDir = path.dirname(packagePath);
  } catch (e) {
    // Oops...
  }

  return Object.assign(
    {},
    entry,
    {name},
    packageData,
    {
      __filename: packagePath,
      __dirname: packageDir
    }
  );
};

const populateCache = () => {
  const cwd = process.env['XIXO'] || process.cwd();
  const cmd = spawn(
    'npm',
    [
      'list',
      '--depth=0',
      '--json=true',
      `--prefix`,
      `${cwd}`
    ],
    {cwd}
  ).stdout.pipe(StreamObject.withParser());

  return new Promise((res, rej) => {
    cmd.on('data', ({key, value}) => {
      if (key === 'dependencies') {
        cache = Object.entries(value).map(decorate);

        res(cache);
      }
    });
  });
};

const findPackages = async (input) => {
  if (!timeout) {
    timeout = setTimeout(populateCache, 10000);
  }

  if (!cache.length) {
    await populateCache();
  }

  return filterByInput(input, cache);
};

const filterByInput = (inputs, packages) => {
  const filtered = [];

  inputs = Array.isArray(inputs) ? inputs : [inputs];
  inputs.forEach(input => {
    packages.forEach(pkg => {
      Object.entries(pkg).forEach(([key, value]) => {
        if (key === input) {
          const defaults = {input, match: {key,value}};

          try {
            filtered.push(Object.assign({}, pkg, defaults, {...require(value)}))
          } catch (e) {
            filtered.push(Object.assign({}, pkg, defaults))
          }
        }
      });
    });
  });

  return filtered;
}

const Package = {
  async route(input) {
    return await findPackages(input);
  },
}

module.exports = Package;
