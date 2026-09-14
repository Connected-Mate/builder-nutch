import test from 'node:test';
import assert from 'node:assert/strict';
import {once} from 'node:events';
import {PassThrough} from 'node:stream';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
import {mkdtempSync,symlinkSync,unlinkSync,rmdirSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {AppServer,Relay,SAFE_CONFIG} from '../Sources/Resources/claude-openai-relay.mjs';
const fixture=fileURLToPath(new URL('./fixtures/claude-openai-app-server.mjs',import.meta.url));
const base={model:'gpt-6-astra',max_tokens:100,messages:[{role:'user',content:'Hello fixture'}]};
async function setup(t,options={}){
 const app=new AppServer(process.execPath,{args:[fixture],cwd:'/tmp'});await app.initialize('/tmp');const relay=new Relay(app,options);relay.safeCwd='/tmp';const url=await relay.listen();t.after(()=>relay.close());
 const request=(body=base,headers={})=>fetch(url+'/v1/messages?beta=true',{method:'POST',headers:{'content-type':'application/json',...(relay.mode==='auto'?{'x-builder-nutch-relay-token':relay.token}:{authorization:`Bearer ${relay.token}`}),...headers},body:JSON.stringify(body)});
 return{app,relay,url,request};
}
test('official adapter initialization and exact safe tool configuration',async t=>{const{app,request}=await setup(t);assert.equal(app.authenticated,true);assert.equal(SAFE_CONFIG['features.shell_tool'],false);assert.equal(SAFE_CONFIG['agents.enabled'],false);const res=await request();assert.equal(res.status,200);assert.equal((await res.json()).content[0].text,'HELLO_FIXTURE');});
test('loopback authentication and browser Origin rejection',async t=>{const{request}=await setup(t);assert.equal((await request(base,{authorization:'Bearer wrong'})).status,401);assert.equal((await request(base,{origin:'https://evil.test'})).status,401);});
test('native tool use/result round trip returns Claude owned tool name',async t=>{const{request,relay}=await setup(t);const body={...base,tools:[{name:'Echo',description:'Echo fixture',input_schema:{type:'object',properties:{text:{type:'string'}}}}]};const first=await(await request(body)).json();assert.equal(first.stop_reason,'tool_use');const tool=first.content[0];assert.equal(tool.name,'Echo');assert.deepEqual(tool.input,{text:'fixture'});const next={...body,messages:[...body.messages,{role:'assistant',content:first.content},{role:'user',content:[{type:'tool_result',tool_use_id:tool.id,content:'ROUNDTRIP_OK'}]}]};const second=await(await request(next)).json();assert.equal(second.stop_reason,'end_turn');assert.equal(second.content[0].text,'ROUNDTRIP_OK');assert.equal(relay.slots.size,0);});
test('SSE has ordered message and text block lifecycle',async t=>{const{request}=await setup(t);const res=await request({...base,stream:true});assert.match(res.headers.get('content-type'),/text\/event-stream/);const output=await res.text();const events=[...output.matchAll(/^event: (.*)$/gm)].map(m=>m[1]);assert.deepEqual(events,['message_start','content_block_start','content_block_delta','content_block_stop','message_delta','message_stop']);assert.match(output,/HELLO_FIXTURE/);});
test('concurrent requests use isolated threads',async t=>{const{request,relay}=await setup(t);const all=await Promise.all(Array.from({length:5},()=>request()));const data=await Promise.all(all.map(r=>r.json()));assert.equal(new Set(data.map(x=>x.id)).size,5);assert.equal(relay.slots.size,0);});
test('client cancellation releases slot and interrupts app-server',async t=>{const{url,relay}=await setup(t);const control=new AbortController();const res=await fetch(url+'/v1/messages',{method:'POST',headers:{authorization:`Bearer ${relay.token}`},body:JSON.stringify({...base,stream:true,messages:[{role:'user',content:'CANCEL_FIXTURE'}]}),signal:control.signal});assert.equal(res.status,200);control.abort();await new Promise(r=>setTimeout(r,40));assert.equal(relay.slots.size,0);});
test('model failure emits an Anthropic error, not a successful empty answer',async t=>{const{request}=await setup(t);const res=await request({...base,messages:[{role:'user',content:'FAIL_FIXTURE'}]});assert.equal(res.status,502);assert.equal((await res.json()).type,'error');});
test('unsupported blocks fail explicitly before creating a thread',async t=>{const{request,relay}=await setup(t);const res=await request({...base,messages:[{role:'user',content:[{type:'document'}]}]});assert.equal(res.status,400);assert.equal(relay.slots.size,0);});
function upstreamFixture(status,type,seen){return(options,callback)=>{seen.push(options);const req=new PassThrough();req.setTimeout=()=>req;req.on('finish',()=>{const res=new PassThrough();res.statusCode=status;res.headers={'content-type':'application/json'};callback(res);res.end(JSON.stringify(status===200?{ok:true}:{error:{type}}));});return req;};}
test('auto mode preserves Claude auth and strips local secret; actual 429 switches sticky',async t=>{const seen=[];const{request}=await setup(t,{mode:'auto',upstream:upstreamFixture(429,'rate_limit_error',seen)});const headers={authorization:'Bearer CLAUDE_FIXTURE','anthropic-beta':'oauth-fixture','x-claude-code-session-id':'same-session'};assert.equal((await request(base,headers)).status,200);assert.equal((await request(base,headers)).status,200);assert.equal(seen.length,1);assert.equal(seen[0].hostname,'api.anthropic.com');assert.equal(seen[0].headers.authorization,'Bearer CLAUDE_FIXTURE');assert.equal(seen[0].headers['anthropic-beta'],'oauth-fixture');assert.equal(seen[0].headers['x-builder-nutch-relay-token'],undefined);});
test('auto preserves non-quota errors without switching',async t=>{const seen=[];const{request,relay}=await setup(t,{mode:'auto',upstream:upstreamFixture(401,'authentication_error',seen)});assert.equal((await request()).status,401);assert.equal(relay.sticky.size,0);});
test('exact token count reports unsupported instead of inventing an estimate',async t=>{const{url,relay}=await setup(t);const res=await fetch(url+'/v1/messages/count_tokens',{method:'POST',headers:{authorization:`Bearer ${relay.token}`},body:JSON.stringify(base)});assert.equal(res.status,404);});
test('observed upstream token usage is returned, cache separated',async t=>{const{request}=await setup(t);const body=await(await request()).json();assert.deepEqual(body.usage,{input_tokens:100,cache_read_input_tokens:20,cache_creation_input_tokens:0,output_tokens:7});});
test('capacity reservation prevents more than eight simultaneous thread starts',async t=>{const{request,relay}=await setup(t);const results=await Promise.all(Array.from({length:12},()=>request({...base,stream:true,messages:[{role:'user',content:'CANCEL_FIXTURE'}]})));assert.equal(results.filter(r=>r.status===200).length,8);assert.equal(results.filter(r=>r.status===429).length,4);assert.equal(relay.slots.size,8);await Promise.all(results.map(r=>r.body.cancel()));});
test('compulsory tool and stop constraints reject instead of silently ignoring',async t=>{const{request}=await setup(t);assert.equal((await request({...base,tool_choice:{type:'any'}})).status,400);assert.equal((await request({...base,stop_sequences:['STOP']})).status,400);});

test('cancel before turn/start reply interrupts the late-started turn',async t=>{
 const{app,relay,url}=await setup(t);const original=app.rpc.bind(app);let release;const waiting=new Promise(r=>{release=r;});const calls=[];
 app.rpc=async(method,params,...rest)=>{calls.push({method,params});const result=await original(method,params,...rest);if(method==='turn/start')await waiting;return result;};
 const control=new AbortController();const response=await fetch(url+'/v1/messages',{method:'POST',headers:{authorization:`Bearer ${relay.token}`},body:JSON.stringify({...base,stream:true,messages:[{role:'user',content:'CANCEL_FIXTURE'}]}),signal:control.signal});assert.equal(response.status,200);control.abort();await new Promise(r=>setTimeout(r,30));assert.equal(relay.slots.size,0);release();await new Promise(r=>setTimeout(r,30));assert.ok(calls.some(c=>c.method==='turn/interrupt'&&c.params.turnId));
});

test('Claude inline system messages preserve authority and native tool continuation',async t=>{
 const{app,request}=await setup(t);const original=app.rpc.bind(app);const starts=[];
 app.rpc=(method,params,...rest)=>{if(method==='thread/start')starts.push(params);return original(method,params,...rest);};
 const system={role:'system',content:[{type:'text',text:'CLIENT_SYSTEM_FIXTURE'}]};
 const body={...base,system:'TOP_SYSTEM_FIXTURE',tools:[{name:'Echo',input_schema:{type:'object',properties:{text:{type:'string'}}}}],messages:[...base.messages,system]};
 const first=await(await request(body)).json();assert.equal(first.stop_reason,'tool_use');
 const follow={...body,messages:[...base.messages,{role:'assistant',content:first.content},{role:'user',content:[{type:'tool_result',tool_use_id:first.content[0].id,content:'INLINE_SYSTEM_OK'}]},system]};
 const next=await(await request(follow)).json();assert.equal(next.content[0].text,'INLINE_SYSTEM_OK');assert.equal(starts.length,1);assert.equal(starts[0].baseInstructions,'TOP_SYSTEM_FIXTURE\n\nCLIENT_SYSTEM_FIXTURE');
});

test('bundled relay entry point also runs through a symbolic path',()=>{
 const directory=mkdtempSync(join(tmpdir(),'relay-entry-test-'));const link=join(directory,'relay.mjs');
 try{symlinkSync(fileURLToPath(new URL('../Sources/Resources/claude-openai-relay.mjs',import.meta.url)),link);assert.match(execFileSync(process.execPath,[link,'--help'],{encoding:'utf8'}),/Usage: relay/);}
 finally{unlinkSync(link);rmdirSync(directory);}
});
