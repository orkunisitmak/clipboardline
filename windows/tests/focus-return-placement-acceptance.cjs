'use strict';
const assert=require('node:assert/strict');

// Closing the shelves hands focus back through the real windows-bridge.ps1.
// The fixture's own WinForms window reports the placement Windows gives it.
module.exports=async function focusReturnPlacementAcceptance({page,application,check,until,fixtureCommand,fixtureState}){
 const place=async state=>{
  await fixtureCommand({action:'placement',state});
  await fixtureCommand({action:'focus',target:'plain'});
  return until(fixtureState,value=>value.placement.startsWith(state.toLowerCase()+':')&&value.foreground===value.handle);
 };
 const open=async source=>{
  await application.evaluate(()=>global.__clipboardLineTest.command('show'));
  await until(()=>application.evaluate(()=>{const window=global.__clipboardLineTest.getWindow();return window.isVisible()&&window.isFocused();}),Boolean);
  const target=await application.evaluate(()=>global.__clipboardLineTest.getTarget());
  assert.equal(target?.handle,source.handle,JSON.stringify(target));
  return target;
 };
 for(const state of ['Maximized','Normal']){
  const before=await place(state);
  await open(before);
  const closed=await page.evaluate(()=>window.clipboardLine.command('hide'));
  assert.ok(!closed.result?.error,closed.result?.error);
  // The acknowledged command proves this state was written after the close.
  const after=await fixtureCommand({action:'report'});
  assert.equal(after.foreground,after.handle,'closing the shelves returns focus to the previous window');
  assert.equal(after.placement,before.placement,'a '+state.toLowerCase()+' previous window keeps its placement when the shelves close');
 }
 check('closing the shelves returns focus to a maximized or normal previous window without resizing it');

 const before=await place('Normal');
 const target=await open(before);
 await fixtureCommand({action:'placement',state:'Minimized'});
 // The previous window is minimized behind the shelves, which stay in front.
 const shelves=await application.evaluate(()=>global.__clipboardLineTest.getWindow().getNativeWindowHandle().readBigUInt64LE().toString());
 await until(fixtureState,value=>value.placement.startsWith('minimized:')&&value.foreground===shelves);
 const restored=await application.evaluate(async(_electron,value)=>{try{return await global.__clipboardLineTest.native.restore(value);}catch(error){return{error:error.message};}},target);
 assert.equal(restored.ok,true,JSON.stringify(restored));
 const after=await fixtureCommand({action:'report'});
 assert.equal(after.foreground,after.handle,'a minimized previous window receives focus again');
 assert.equal(after.placement,before.placement,'a minimized previous window comes back at its earlier placement');
 await page.evaluate(()=>window.clipboardLine.command('hide'));
 check('focus return still brings a minimized previous window back');
};
