/**
 * Executes a CFML file and outputs whatever the template outputs using cfoutput or the buffer.
 * .
 * {code:bash}
 * execute myFile.cfm
 * {code}
 * .
 * You can also pass variables to the template by passing any number of additional parameters to this
 * command.
 * .
 * If you're using named parameters, they will be available by ${name} in the variables scope.
 * variables.$foo, variables.$bum
 * .
  * {code:bash}
 * execute file=myFile.cfm foo=bar bum=baz
 * {code}
 * .
 * If you're using positional parameters, they will be available as ${position} in the variables scope.
 * variables.$1, variables.$2 
 * .
  * {code:bash}
 * execute myFile.cfm bar baz
 * {code}
 
 **/
component extends="commandbox.system.BaseCommand" aliases="" excludeFromHelp=false{

	/**
	 * @file.hint The file to execute
	 **/
	function run( required file ){
		
		// Make file canonical and absolute
		arguments.file = fileSystemUtil.resolvePath( arguments.file );

		if( !fileExists( arguments.file ) ){
			return error( "File: #arguments.file# does not exist!" );
		}
		
		// Only forward slashes match CF's mappings
		arguments.file = replace( arguments.file, '\', '/' );
		// For non-Unix paths, strip  drive letter so path is relative.
		// This only works because Railo sees the drive root as the web root so / matches it
		// ONLY WORKS FOR FILES ON THE SAME DRIVE AS COMMANDBOX!! See COMMANDBOX-104
		if( !arguments.file.startsWith( '/' ) ) {
			// Strip drive letter
			arguments.file = mid( arguments.file, 3, len( arguments.file ) );			
		}		
		
		// Parse arguments
		var vars = parseArguments( arguments );
		
		try{
			// we use the executor to capture output thread safely
			var out = wirebox.getInstance( "Executor" ).run( arguments.file, vars );
		} catch( any e ){
			print.boldGreen( "Error executing #arguments.file#: " );
			return error( '#e.message##CR##e.detail##CR##e.stackTrace#' );
		}

		return ( out ?: "The file '#arguments.file#' executed succesfully!" );
	}

	/**
	* Parse arguments and return a collection
	*/
	private struct function parseArguments( required args ){
		var parsedArgs = {};
		
		for( var arg in args ) {
			argName = arg;
			if( !isNull( args[arg] ) && arg != 'file' ) {
				// If positional args, decrement so they start at 1
				if( isNumeric( argName ) ) {
					argName--;
				}
				parsedArgs[ '$' & argName ] = args[arg];
			}
		}
		return parsedArgs;
	}
	
}