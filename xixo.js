const Package = require('./Package');
const path = require('path');
const util = require('util');
const spawn =  util.promisify(require('child_process').spawn);

async function xixo(input) {
  const packages = await Package.route(input)
  const modules = new Set();

  return new Promise((res, rej) => {
    const promises = packages.map(
      async (p) => {
        modules.add(path.join(p.__dirname, 'node_modules'));

        if (typeof p.xixo == 'function') {
          return {...p, ...(await p.xixo(input))};
        } else {
          return p;
        }
      }
    );

    Promise.all(promises).then((output) => res({
      input,
      packages: output,
    }));
  })
};

exports.xixo = xixo;
