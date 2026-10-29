'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {spawnSync}=require('node:child_process'),path=require('node:path');

// ICU takes its default locale from the environment. The shelf search fixtures
// must give the same results under a Turkish locale as under any other.
for(const locale of ['tr_TR.UTF-8','az_AZ.UTF-8','en_US.UTF-8']){
  test(`shelf search folding is locale-independent under ${locale}`,()=>{
    const environment={...process.env,LANG:locale,LC_ALL:locale};delete environment.NODE_TEST_CONTEXT;
    const result=spawnSync(process.execPath,['--test',path.join(__dirname,'shelf-render.test.cjs')],{env:environment,encoding:'utf8',timeout:60000});
    assert.equal(result.status,0,result.stdout.slice(-2000)+result.stderr.slice(-2000));
  });
}
