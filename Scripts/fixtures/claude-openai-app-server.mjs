import readline from 'node:readline';
let n=0;const threads=new Map(),pending=new Map();
const send=x=>process.stdout.write(JSON.stringify(x)+'\n');
const notify=(method,params)=>send({method,params});
function complete(id,text){notify('thread/tokenUsage/updated',{threadId:id,tokenUsage:{last:{inputTokens:120,cachedInputTokens:20,cacheWriteInputTokens:0,outputTokens:7}}});notify('item/agentMessage/delta',{threadId:id,turnId:'turn_'+id,delta:text});notify('turn/completed',{threadId:id,turn:{id:'turn_'+id,status:'completed'}});}
for await(const line of readline.createInterface({input:process.stdin})){
 const x=JSON.parse(line),p=x.params??{};
 if(!x.method){const id=pending.get(x.id);if(id){pending.delete(x.id);setTimeout(()=>complete(id,x.result?.contentItems?.map(b=>b.text).join('')??'BAD'),10);}continue;}
 const reply=result=>send({id:x.id,result});
 switch(x.method){
 case'initialize':reply({});break;
 case'config/read':reply({config:{mcp_servers:{danger:{command:'do-not-run'}}}});break;
 case'account/read':reply({account:{type:'chatgpt'}});break;
 case'model/list':reply({data:[{model:'gpt-6-astra',displayName:'GPT-6 Astra'}],nextCursor:null});break;
 case'thread/start':{
 if(p.environments?.length!==0||p.config?.['mcp_servers.danger.enabled']!==false||p.config?.['features.shell_tool']!==false||p.config?.['features.plugins']!==false||p.approvalPolicy!=='never'){send({id:x.id,error:{code:-32000,message:'UNSAFE CONFIG'}});break;}
 const id='thread_'+(++n);threads.set(id,p);reply({thread:{id}});break;}
 case'turn/start':{
 reply({turn:{id:'turn_'+p.threadId}});const t=threads.get(p.threadId);const text=p.input[0].text;
 if(text.includes('CANCEL_FIXTURE'))break;
 if(text.includes('FAIL_FIXTURE')){setTimeout(()=>notify('turn/completed',{threadId:p.threadId,turn:{status:'failed'}}),10);break;}
 if(t.dynamicTools.length){const id='rpc_'+p.threadId;pending.set(id,p.threadId);setTimeout(()=>send({id,method:'item/tool/call',params:{threadId:p.threadId,turnId:'turn_'+p.threadId,callId:id,namespace:null,tool:t.dynamicTools[0].name,arguments:{text:'fixture'}}}),10);}
 else setTimeout(()=>complete(p.threadId,'HELLO_FIXTURE'),10);break;}
 case'turn/interrupt':reply({});break;
 case'thread/unsubscribe':threads.delete(p.threadId);reply({});break;
 }
}
