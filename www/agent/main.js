dojo.addOnLoad(function(){
			   EventLog.log("Inteface loaded");
			   
			   dijit.byId("loginpane").show();
			   
			   //Agent.states = ["idle", "ringing", "precall", "oncall", "outgoing", "released", "warmtransfer", "wrapup"];
			   
			   dojo.byId("brand").stateChanger = dojo.subscribe("agent/state", function(data){
																var node = dojo.byId("brand");
																
																switch(data.state){
																case "ringing":
																case "precall":
																case "oncall":
																case "outgoing":
																case "wrapup":
																node.innerHTML = data.brand;
																node.style.visibility = "visible";
																break;
																
																default:
																node.style.visibility = "hidden";
																}
																});
			   
			   dojo.byId("statedisp").stateChanger = dojo.subscribe("agent/state", function(data){
																	var node = dojo.byId("statedisp");
																	node.innerHTML = "State:" + data.state;
																	});
			   
			   dijit.byId("bgoreleased").stateChanger = dojo.subscribe("agent/state", function(data){
																	   var widget = dijit.byId("bgoreleased");
																	   if(data.state == "released"){
																	   widget.attr('style', 'display:none');
																	   }
																	   else{
																	   widget.attr('style', 'display:inline');
																	   }
																	   });
			   
			   dijit.byId("bgoavail").stateChanger = dojo.subscribe("agent/state", function(data){
																	var widget = dijit.byId("bgoavail");
																	switch(data.state){
																	case "released":
																	case "wrapup":
																	widget.attr('style', 'display:inline');
																	break;
																	default:
																	widget.attr('style', 'display:none');
																	}
																	});
			   
			   dijit.byId("eventLogText").eventLogPushed = dojo.subscribe("eventlog/push", function(text){
																		  var oldval = dijit.byId("eventLogText").value;
																		  dijit.byId("eventLogText").setValue(oldval + "\n" + text)
																		  });
			   
			   var loginform = dijit.byId("loginform")
			   dojo.connect(loginform, "onSubmit", function(e){
							e.preventDefault();
							if (loginform.isValid()){
							dojo.xhrGet({
										url:"/getsalt",
										handleAs:"json",
										error:function(response, ioargs){
										dojo.byId("loginerrp").style.display = "block";
										dojo.byId("loginerrspan").innerHTML = response.responseText;
										},
										load:function(response, ioargs){
										EventLog.log("Recieved salt");
										salt = response.salt;
										attrs = loginform.attr("value");
										md5pass = dojox.encoding.digests.MD5(attrs.password, dojox.encoding.digests.outputTypes.Hex);
										salted = dojox.encoding.digests.MD5(salt + md5pass, dojox.encoding.digests.outputTypes.Hex);
										values = attrs;
										values.password = salted;
										dojo.xhrPost({
													 url:"/login",
													 handleAs:"json",
													 content:values,
													 load:function(response2, ioargs2){
													 if(response2.success){
													 EventLog.log("Logged in");
													 dijit.byId("loginpane").hide();
													 dojo.byId("main").style.display="block";
													 dojo.byId("main").style.visibility = "visible";
													 dojo.byId("agentname").innerHTML = attrs.username;
													 console.log(response2);
													 agent = new Agent(attrs.username);
													 agent.stopwatch.onTick = function(){
													 var elapsed = agent.stopwatch.time();
													 var d = new Date();
													 d.setHours(0);
													 d.setMinutes(0);
													 d.setSeconds(elapsed);
													 dojo.byId("timerdisp").innerHTML = d.getHours() + ":" + d.getMinutes() + ":" + d.getSeconds();
													 }
													 buildReleaseMenu(agent);
													 }
													 else{
													 dojo.byId("loginerrp").style.display = "block";
													 dojo.byId("loginerrspan").innerHTML = response2.message;
													 }
													 }
													 });
										}
										});
							}
							});
			   
			   buildReleaseMenu = function(agent){
			   dojo.xhrGet({
						   url:"/releaseopts",
						   handleAs:"json",
						   error:function(response, ioargs){
						   var menu = dijit.byId("releasedmenu");
						   var item = new dijit.MenuItem({
														 label:"Default",
														 onClick:function(){agent.setState("released", "Default"); }
														 });
						   menu.addChild(item);
						   },
						   load:function(reponse, ioargs){
						   if(response.success){
						   var menu = dijit.byId("releasedmenu");
						   var item = new dijit.MenuItem({
														 label:"Default",
														 onClick:function(){agent.setState("released", "Default"); }
														 });
						   menu.addChild(item);
						   }
						   else{
						   var menu = dijit.byId("releasedmenu");
						   var item = new dijit.MenuItem({
														 label:"Default",
														 onClick:function(){agent.setState("released", "Default"); }
														 });
						   menu.addChild(item);
						   }
						   }
						   })
			   } 
			   });