/**
*********************************************************************************
* Copyright Since 2014 CommandBox by Ortus Solutions, Corp
* www.coldbox.org | www.ortussolutions.com
********************************************************************************
* @author Brad Wood, Luis Majano, Denny Valliant
*
* I am the ForgeBox endpoint.  I wrap CFML's coolest package repository
*/
component accessors="true" implements="IEndpointInteractive" singleton {
		
	// DI
	property name="CR" 					inject="CR@constants";
	property name="consoleLogger"		inject="logbox:logger:console";
	property name="forgeBox" 			inject="ForgeBox";
	property name="tempDir" 			inject="tempDir@constants";
	property name="semanticVersion"		inject="semanticVersion";
	property name="artifactService" 	inject="ArtifactService";
	property name="packageService" 		inject="packageService";
	property name="configService" 		inject="configService";
	property name="endpointService"		inject="endpointService";
	property name="fileSystemUtil"		inject="FileSystem";
	property name="fileEndpoint"		inject="commandbox.system.endpoints.File";
	
	// Properties
	property name="namePrefixes" type="string";
	
	function init() {
		setNamePrefixes( 'forgebox' );
		return this;
	}
		
	public string function resolvePackage( required string package, boolean verbose=false ) {
		var slug = parseSlug( arguments.package );
		var version = parseVersion( arguments.package );
				
		// If we have a specific version and it exists in artifacts, use it.  Otherwise, to ForgeBox!!
		if( semanticVersion.isExactVersion( version ) && artifactService.artifactExists( slug, version ) ) {
			consoleLogger.info( "Package found in local artifacts!");	
			// Install the package
			var thisArtifactPath = artifactService.getArtifactPath( slug, version );		
			// Defer to file endpoint
			return fileEndpoint.resolvePackage( thisArtifactPath, arguments.verbose );
		} else {
			return getPackage( slug, version, arguments.verbose );			 
		}
	}
	
	public function getDefaultName( required string package ) {
		// if "foobar@2.0" just return "foobar"
		return listFirst( arguments.package, '@' );
	}

	public function getUpdate( required string package, required string version, boolean verbose=false ) {
		var slug = parseSlug( arguments.package );
		var boxJSONversion = parseVersion( arguments.package );
		var result = {
			isOutdated = false,
			version = ''
		};
		
		// Only bother checking if we have a version range.  If an exact version is stored in 
		// box.json, we're never going to update it anyway.
		if( semanticVersion.isExactVersion( boxJSONversion ) ) {
			return result;
		}
		
		// Verify in ForgeBox
		var entryData = forgebox.getEntry( slug );
		
		entryData.versions.sort( function( a, b ) { return semanticVersion.compare( b.version, a.version ) } );
		
		var found = false;
		for( var thisVersion in entryData.versions ) {
			// Look for a version on ForgeBox that satisfies our range
			if( semanticVersion.satisfies( thisVersion.version, boxJSONversion ) ) {
				result.version = thisVersion.version;
				found = true;
				// Only flag it as outdated if the matching version is newer.
				if( semanticVersion.isNew( current=version, target=thisVersion.version, checkBuildID=false ) ) {
					result.isOutdated = true;					
				} 
				break;
			}
		}
		
		if( !found ) {
			// If we requsted stable and all releases are pre-release, just grab the latest
			if( boxJSONversion == 'stable' && arrayLen( entryData.versions ) ) {
				result.version = entryData.versions[ 1 ].version;
				result.isOutdated = true;					
			}
		}
		
		return result;		
	}

	public string function createUser(
		required string username,
		required string password,
		required string email,
		required string firstName,
		required string lastName ) {
			
		try {
			
			var results = forgebox.register(
				username = arguments.username,
				password = arguments.password,
				email = arguments.email,
				FName = arguments.firstName,
				LName = arguments.lastName
			);
			return results.APIToken;
					
		} catch( forgebox var e ) {
			// This can include "expected" errors such as "Email already in use"
			throw( e.message, 'endpointException', e.detail );
		}
	}
	
	public string function login( required string userName, required string password ) {
			
		try {
			
			var results = forgebox.login( argumentCollection=arguments );
			return results.APIToken;
					
		} catch( forgebox var e ) {
			// This can include "expected" errors such as "Email already in use"
			throw( e.message, 'endpointException', e.detail );
		}
		
	}
	
	public function publish( required string path ) {
		
		if( !packageService.isPackage( arguments.path ) ) {
			throw( 'Sorry but [#arguments.path#] isn''t a package.', 'endpointException', 'Please double check you''re in the correct directory or use "package init" to turn your directory into a package.' );			
		}
		
		var boxJSON = packageService.readPackageDescriptor( arguments.path );
		
		var props = {}
		props.slug = boxJSON.slug;
		props.version = boxJSON.version;
		props.boxJSON = serializeJSON( boxJSON );
		props.isStable = !semanticVersion.isPreRelease( boxJSON.version );
		props.description = boxJSON.description;
		props.descriptionFormat = 'text';
		props.installInstructions = boxJSON.instructions;
		props.installInstructionsFormat = 'text';
		props.changeLog = boxJSON.changeLog;
		props.changeLogFormat = 'text';
		props.APIToken = configService.getSetting( 'endpoints.forgebox.APIToken', '' );
		
		// Look for readme, instruction, and changelog files
		for( var item in [
			{ variable : 'description', file : 'readme' },
			{ variable : 'installInstructions', file : 'instructions' },
			{ variable : 'changelog', file : 'changelog' }
		] ) {
			// Check for no ext or .txt or .md in reverse precendence.
			for( var ext in [ '', '.txt', '.md' ] ) {
				// Case insensitive search for file name
				var files = directoryList(path=arguments.path,filter=function( path ){ return path contains ( item.file & ext); } )
				if( arrayLen( files ) ) {
					// If found, read in the first one found.
					props[ item.variable ] = fileRead( files[ 1 ] );
					props[ item.variable & 'Format' ] = ( ext == '.md' ? 'md' : 'text' );
				}
			}
		}
		
		try {			
			forgebox.publish( argumentCollection=props );
					
		} catch( forgebox var e ) {
			// This can include "expected" errors such as "User not authenticated"
			throw( e.message, 'endpointException', e.detail );
		}
	}	

	/*
	* Figures out what version of a package would be installed with a given semver range without actually going through the installation.
	* @slug Slug of package
	* @version Version range to satisfy
	* @entryData Optional struct of entryData which skips the ForgeBox call.
	*/
	function findSatisfyingVersion( required string slug, required string version, struct entryData ) {
		
			// Use passed in entrydata, or go get it from ForgeBox.
			arguments.entryData = arguments.entryData ?: forgebox.getEntry( arguments.slug );
			
			arguments.entryData.versions.sort( function( a, b ) { return semanticVersion.compare( b.version, a.version ) } );
			
			var found = false;
			for( var thisVersion in arguments.entryData.versions ) {
				if( semanticVersion.satisfies( thisVersion.version, arguments.version ) ) {
					return thisVersion;
				}
			}
			
			// If we requsted stable and all releases are pre-release, just grab the latest
			if( arguments.version == 'stable' && arrayLen( arguments.entryData.versions ) ) {
				return arguments.entryData.versions[ 1 ]; 
			} else {
				throw( 'Version [#arguments.version#] not found for package [#arguments.slug#].', 'endpointException', 'Available versions are [#arguments.entryData.versions.map( function( i ){ return ' ' & i.version; } ).toList()#]' );					
			}
	}
		
	/*
	* Parses just the slug portion out of an endpoint ID
	* @package The full endpointID like foo@1.0.0 
	*/
	public function parseSlug( required string package ) {
		return listFirst( arguments.package, '@' );
	}

	/*
	* Parses just the version portion out of an endpoint ID
	* @package The full endpointID like foo@1.0.0 
	*/
	public function parseVersion( required string package ) {
		var version = 'stable';
		// foo@1.0.0
		if( arguments.package contains '@' ) {
			// Note this can also be a semver range like 1.2.x, >2.0.0, or 1.0.4-2.x
			// For now I'm assuming it's a specific version
			version = listRest( arguments.package, '@' );
		}
		return version;
	}

	
	// Private methods

	private function getPackage( slug, version, verbose=false ) {		
	
		try {
			// Info
			consoleLogger.warn( "Verifying package '#slug#' in ForgeBox, please wait..." );
						
			var entryData = forgebox.getEntry( slug );
					
			// Verbose info
			if( arguments.verbose ){
				consoleLogger.debug( "Package data retrieved: ", entryData );
			}
			
			// entrylink,createdate,lname,isactive,installinstructions,typename,version,hits,coldboxversion,sourceurl,slug,homeurl,typeslug,
			// downloads,entryid,fname,changelog,updatedate,downloadurl,title,entryrating,summary,username,description,email
							
			if( !val( entryData.isActive ) ) {				
				throw( 'The ForgeBox entry [#entryData.title#] is inactive.', 'endpointException' );
			}
	
			var satisfyingVersion = findSatisfyingVersion( slug, version, entryData );
			arguments.version = satisfyingVersion.version;
			var downloadURL = satisfyingVersion.downloadURL;
						
			if( !len( downloadurl ) ) {
				throw( 'No download URL provided in ForgeBox.  Manual install only.', 'endpointException' );
			}
			
			consoleLogger.info( "Installing version [#arguments.version#]." );
			
			try {
				forgeBox.recordInstall( arguments.slug, arguments.version );
			} catch( forgebox var e ) {
				consoleLogger.warn( e.message & CR & e.detail );
			}
					
			var packageType = entryData.typeSlug;
			
			// Advice we found it
			consoleLogger.info( "Verified entry in ForgeBox: '#slug#'" );
				
			// If the local artifact doesn't exist, download and create it
			if( !artifactService.artifactExists( slug, version ) ) {
					
				// Test package location to see what endpoint we can refer to.
				var endpointData = endpointService.resolveEndpoint( downloadURL, 'fakePath' );
				
				consoleLogger.info( "Deferring to [#endpointData.endpointName#] endpoint for ForgeBox entry [#slug#]..." );
				
				var packagePath = endpointData.endpoint.resolvePackage( endpointData.package, arguments.verbose );
								
				// Cheat for people who set a version, slug, or type in ForgeBox, but didn't put it in their box.json
				var boxJSON = packageService.readPackageDescriptorRaw( packagePath );
				if( !structKeyExists( boxJSON, 'type' ) || !len( boxJSON.type ) ) { boxJSON.type = entryData.typeslug; }
				if( !structKeyExists( boxJSON, 'slug' ) || !len( boxJSON.slug ) ) { boxJSON.slug = entryData.slug; }
				if( !structKeyExists( boxJSON, 'version' ) || !len( boxJSON.version ) ) { boxJSON.version = version; }
				packageService.writePackageDescriptor( boxJSON, packagePath );
				
				consoleLogger.info( "Storing download in artifact cache..." );
												
				// Store it locally in the artfact cache
				artifactService.createArtifact( slug, version, packagePath );
													
				consoleLogger.info( "Done." );
				
				return packagePath;
				
			} else {
				consoleLogger.info( "Package found in local artifacts!");
				var thisArtifactPath = artifactService.getArtifactPath( slug, version );		
				// Defer to file endpoint
				return fileEndpoint.resolvePackage( thisArtifactPath, arguments.verbose );
			}
			
			
		} catch( forgebox var e ) {
			// This can include "expected" errors such as "slug not found"
			throw( '#e.message##CR##e.detail#', 'endpointException' );
		}		
	}
	
}