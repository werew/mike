#!/bin/sh

# Codes d'erreur 
ERR_INVOPT=1
ERR_NFOUND=2
ERR_PUSAGE=3
ERR_NOTRGT=4
ERR_INTRGT=5
ERR_BADCMD=6
ERR_BADMKF=7
ERR_DPCYCL=8

# Initialise la variable MAKEFILE avec le nom d'un fichier présent dans le répertoire courant.
# Noms possibles (en ordre de preference): 'makefile' 'Makefile' 'mikefile' 'Mikefile'. Si aucun de ces fichiers existe, la variable reste vide  
# NB: l'orde de preference est similaire a celui du logiciel 'make'
MAKEFILE=$( ls [mM][ai]kefile 2> /dev/null | head -n 1)

# Initialise les options à faux par defaut 
KEEPGOING=false
JUSTPRINT=false
SILENT=false

# Fichiers temporaires
MAKETMP="/tmp/$( basename $0 ).$$"  # Contient une version essentielle du fichier $MAKEFILE après le passage du preprocesseur
BROKENDEPS="/tmp/brkdp.$$"	    # Quand l'options '-k' a été activé, contient les dependences qui ont reporté un erreur de compilation
BUILDLIST="/tmp/bldlst.$$"	    # Liste des appels 



# Fonction de depart du program 
main ()
{

	ARGS=$(getopt -n $0 -o f:knc:s -l help -- "$@")

	if [ $? -ne 0 ]	# Test de validite des options et arguments
	then
		error $ERR_INVOPT
	fi

	set -- $ARGS
	
	for arg
	do
		case $arg in 
			-f)	MAKEFILE=$(clean_delimiters $2) ; shift 2
				;;
			-k)	KEEPGOING=true; touch $BROKENDEPS ; shift
				;;
			-n)	JUSTPRINT=true; shift
				;;
			-s)	SILENT=true; shift
				;;
			-c)	cd $(clean_delimiters $2) ; shift 2
				;;
			--help) print_help
				;;
			--)	shift; break
				;;
		esac
	done
	
	TARGET=$(clean_delimiters $1)
	
	# Traitement du makefile #

	if ! [ -f "$MAKEFILE" ] # Teste l'existence du makefile
	then
		error $ERR_BADMKF $MAKEFILE
	fi

	preprocess $MAKEFILE > $MAKETMP
	trap 'rm -f "$MAKETMP" "$BROKENDEPS" "$BUILDLIST"' EXIT

	# Traitement cible principale #

	if [ -z "$TARGET" ]   # Teste si l'usageur a specifié une cible
	then 
		TARGET=$(default_target) 		# Cherche une cible par defaut
		[ -z "$TARGET" ] && error $ERR_NOTRGT	# Erreur si le makefile ne contient aucune cible 
	else
		is_target "$TARGET" || error $ERR_INTRGT "$TARGET"  # Teste si la cible specifié est bien presente dans le makefile
	fi

	build "$TARGET"

	
}
	


build () {
	
	echo "$1" >> $BUILDLIST

	######### GESTION DES DEPENDANCES #########

	DEPS=$(getdeps "$1")

	# Mise à jour de tous les dependances par des appels recursifs #
	for dep in $DEPS
	do
		if is_target "$dep" # Teste si la dep. est une cible
		then	
			 if in_stack "$dep" 
			 then 
				 DEPS=$(remove_inv_dep "$dep" "$DEPS")
				 (error $ERR_DPCYCL $1 $dep)
				 continue
			 fi
			(build "$dep") || $KEEPGOING || exit 1	# La dep. est une cible, il faut la mettre à jour (on utilise un subshell)
		else
			if ! [ -e "$dep" ] # Teste si la dep. est un fichier
			then
				 echo "$1" >> $BROKENDEPS 	# La dep. n'est ni une cible ni un fichier, la cible ne peut pas etre compilé 
				 error $ERR_NFOUND "$dep" "$1"  # Returne un erreure. NB: 'error' ne quitte pas le programme si 'build' a été
			fi					# executé dans une subshell.
		fi
	done

	# Dans le cas de '-k', quitte l'execution de 'build' et passe à la cible suivante si il y a des dependencies qui
	# ne pouvont pas etre satisfée
	
	if $KEEPGOING && broken_deps "$DEPS" 
	then
		echo "$1" >> $BROKENDEPS # Considere la cible courant comme une dependence pas satisfee
		echo "$0: Skipping $1. Error while building dependencies." >&2
		return 1
	fi
	


	######### EXECUTION DES COMMANDES #########

	
	# Si la cible n'existe pas il faut forcement la traiter #
	
	if ! [ -e "$1" ]
	then  
		execute "$1"; return
	fi


	# Si la cible existe deja, il faut tester s'il y a des dep. traite recentement #

	for dep in $DEPS
	do
		if  [ $(find -newer "$1" -name "$dep") ] || ! [ -e "$dep" ]  # La cible doit etre mise a jour seulement si:
		then							     # a) Il y a une dependencie plus recent que la cible
			execute "$1"					     # b) Il y a une dependencie qui n'a pas produit aucun fichier
			return						     #    (donc elle a ete forcement traite).
		fi


	done

	# Affiche un avis si la cible principale est deja à jour #

	[ "$1" = "$TARGET" ] && echo "$0: '$1' is up to date, stop bothering me!"
	return 0
}



# Obtient la liste des dependencies d'une cible
# @param: cible 
getdeps(){
	sed -n "/^$(escape_bre $1):/ s///p" < $MAKETMP
}

# Obtient la liste des commandes associé à une cible
# @param: cible 
getcmds(){
	sed -n "/^$(escape_bre $1):/,/^[^\t].*:/p" < $MAKETMP | sed -n '/^\t/ s///p'
}

# Return le nom de la premiere cible presente dans le makefile
default_target(){
	sed -n '/^[^[:space:]]*:/ s/^\([^[:space:]]*\):.*/\1/p' < $MAKETMP | sed "1!d"
}	

# Teste si l'argument est une cible 
# @param nom a tester
is_target(){
	grep -q "^$(escape_bre $1):" < $MAKETMP
	return $?
}

# Execute le commandes associé à une cible
# @param cible
execute(){
	RECIPE=$(getcmds $1)
	local IFS='
'			    # IFS='\n'
	for CMD in $RECIPE
	do	
		$SILENT || echo "$CMD" # Affichage commande
		$JUSTPRINT && continue  
		if ! sh -c "$CMD" mike # Execute la commande et teste sa valeur de retur
		then
			$KEEPGOING || error $ERR_BADCMD "$CMD" 
			echo $1 >> $BROKENDEPS; return 1
		fi
	done
}

# Teste si une liste de dependences est intacte (toutes les dependances pouvont etre satisfée)
# @param liste de dependances
broken_deps(){
	for dep in $1
	do	
		grep -q "^$(escape_bre $dep)$" < $BROKENDEPS && return 0
	done
	return 1
}

in_stack(){
	grep -q "^$(escape_bre $1)$" < $BUILDLIST
}


# Simplifie le makefile en enlevant les commentaires, le lignes vides et bien positionnant le cibles
# @param parcour vers le makefile
preprocess(){
	sed  's/^[:space:]*#.*$//' < $1 | grep -v '^[[:space:]]*$' | sed 's/^[ ]*\(.*:\)/\1/'
}

# S'il y a, enleve les apostrophes aux extremite d'un argument. Ex: 'toto' --> toto
# @param l'argument a traiter
clean_delimiters(){
	echo "$1" | sed "s:^'\(.*\)'$:\1:"
}

# Eschape les caracteres consideree speciales dans une expression regulaire de type basic (BRE)
# @param chaine a traiter
escape_bre(){
	echo "$1" | sed 's/[.[\*^$]/\\&/g'
}


remove_inv_dep(){
	echo "$2" | sed "s/$(escape_bre $1)//g"
}

# Traite des erreures. Chaque erreure est identifie par un code.
# @param code d'erreur
# @param argument 1 de l'erreur (optionnel)
# @param argument 2 de l'erreur (optionnel)
error(){
	case $1 in
		$ERR_PUSAGE) echo "usage: $0 [options] <target>";; # Pas utilise pour le moment
		$ERR_NFOUND) echo "$0: no rule to make '$2' needed by '$3'";;
		$ERR_INVOPT) echo "Try: '$0 --help' for more informations";;
		$ERR_NOTRGT) echo "$0: '$MAKEFILE' doesn't contain any target, what am I supposed to do?";;
		$ERR_INTRGT) echo "$0: invalid target '$2', what are you trying to build?!";;
		$ERR_BADCMD) echo "$0: fail to execute command '$2'...check it out please!";;
		$ERR_BADMKF) echo "$0: cannot find '$2', give me a valid file next time.";;
		$ERR_DPCYCL) echo "$0: repetition $2 <-- $3 depency dropped";;
	esac >&2
	exit 1
} 

# Affiche des informations a propos de l'utilise du programme
print_help (){
	cat << END_HELP

'$0' is shell script who emulates a reduced and more informal version of the well knowm 'make'.
If you know how to use 'make' then you know how to use '$0', otherwise it would be nice to have 
a look here: http://www.gnu.org/software/make/manual/make.html

As I said '$0' is a reduced version of 'make', indeed it accepts only few options and a basic 
synthax for the makefile ( 'makefile', 'Makefile', 'mikefile' or 'Mikefile').

Options:
		-n
		Just print the commands without executing them.

		-k 
		Keep going where possible if a command fails, compiling the targets 
		who don't depend on the one who just failed.

	 	-f <file>
		Use 'file' as makefile.
		
		--help
		Print this page.

END_HELP
	exit 0
}

main "$@"
